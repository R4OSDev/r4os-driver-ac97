const r4os = @import("r4os");
const std = @import("std");
const pcm = r4os.audio_pcm;
const queue_state = @import("queue_state.zig");
const work_gate = @import("work_gate.zig");
const idle_drain = @import("idle_drain.zig");

comptime {
    asm (r4os.r4dev.driverEntriesAsm("ac97_init", "ac97_shutdown"));
}

const CLASS_MULTIMEDIA: u8 = 0x04;
const SUBCLASS_AUDIO: u8 = 0x01;

const NAM_RESET: u16 = 0x00;
const NAM_MASTER_VOLUME: u16 = 0x02;
const NAM_PCM_OUT_VOLUME: u16 = 0x18;
const NAM_EXT_AUDIO_CTRL: u16 = 0x2A;
const NAM_PCM_FRONT_RATE: u16 = 0x2C;

const PO_BDBAR: u16 = 0x10;
const PO_CIV: u16 = 0x14;
const PO_LVI: u16 = 0x15;
const PO_SR: u16 = 0x16;
const PO_CR: u16 = 0x1B;

const CR_RUN: u8 = 0x01;
const CR_RESET: u8 = 0x02;
const CR_LVBIE: u8 = 0x04;
const CR_FEIE: u8 = 0x08;
const CR_IOCE: u8 = 0x10;
const CR_IRQ_ENABLE: u8 = CR_LVBIE | CR_FEIE | CR_IOCE;
const SR_CLEAR: u16 = 0x001C;
const SR_DCH: u16 = 0x0001;
const SR_CELV: u16 = 0x0002;
const SR_LVBCI: u16 = 0x0004;
const SR_BCIS: u16 = 0x0008;
const SR_FIFOE: u16 = 0x0010;
const BDL_IOC: u16 = 0x8000;

const TARGET_RATE: u16 = @intCast(pcm.TARGET_RATE);
const MIN_RATE: u32 = 8000;
const MAX_RATE: u32 = 192_000;
const MAX_DMA_BYTES: u32 = 4096;
const DMA_BUFFER_COUNT: usize = 8;
const BDL_ENTRY_COUNT: usize = 32;
const IRQ_ROUTE_CAPACITY: usize = 1;
const WORK_HANDLE_CAPACITY: usize = 2;
const REFILL_DEADLINE_MS: u64 = 10;
const REFILL_BUDGET_MS: u64 = 2;
// 0.56.40: hz-neutral in ms (bei 100 Hz wie zuvor 10/200 Ticks).
const PLAYBACK_WAIT_MS: u64 = 100;
const DRAIN_WAIT_MS: u64 = 2000;

const BdlEntry = extern struct {
    addr: u32,
    samples: u16,
    control: u16,
};

const State = struct {
    api: *const r4os.r4dev.DriverApi = undefined,
    initialized: bool = false,
    info: r4os.abi.PciDeviceInfo = .{},
    nam_port: u16 = 0,
    nabm_port: u16 = 0,
    backend: r4os.r4dev.AudioOutputIdleBackend = .{
        .base = .{ .outputs = .{ .query = queryOutput, .select = selectOutput, .active = activeOutput } },
        .idle = idlePlaybackBackend,
    },
    backend_registered: bool = false,
    present: bool = false,
    stream_lock: bool = false,
    shutting_down: bool = false,
    playback_started: bool = false,
    dch_active: bool = false,
    queue: queue_state.DescriptorQueue = queue_state.DescriptorQueue.init(BDL_ENTRY_COUNT, DMA_BUFFER_COUNT),
    bdl: r4os.abi.DmaBuffer = .{},
    dma: [DMA_BUFFER_COUNT]r4os.abi.DmaBuffer = .{r4os.abi.DmaBuffer{}} ** DMA_BUFFER_COUNT,
    write_count: u64 = 0,
    refill_count: u64 = 0,
    write_total_ticks: u64 = 0,
    write_max_ticks: u64 = 0,
    write_last_ticks: u64 = 0,
    refill_total_ticks: u64 = 0,
    refill_max_ticks: u64 = 0,
    refill_last_ticks: u64 = 0,
    reset_count: u64 = 0,
    stop_count: u64 = 0,
    drain_count: u64 = 0,
    drain_timeout_count: u64 = 0,
    timeout_count: u64 = 0,
    dch_count: u64 = 0,
    underrun_count: u64 = 0,
    fifo_error_count: u64 = 0,
    recovery_count: u64 = 0,
    status_irq_count: u64 = 0,
    normal_completion_count: u64 = 0,
    busy_count: u64 = 0,
    dropped_buffer_count: u64 = 0,
    error_count: u64 = 0,
    converted_frame_count: u64 = 0,
    last_result: i32 = 0,
    last_status: u16 = 0,
    last_source_rate: u32 = 0,
    last_source_channels: u16 = 0,
    last_source_format: u16 = 0,
    last_output_frames: usize = 0,
    irq_registered: bool = false,
    irq_mode: u8 = 0,
    irq_routes: [IRQ_ROUTE_CAPACITY]u8 = .{0xFF} ** IRQ_ROUTE_CAPACITY,
    irq_route_count: usize = 0,
    irq_active_route: u8 = 0xFF,
    irq_count: u64 = 0,
    irq_handled: u64 = 0,
    irq_unhandled: u64 = 0,
    irq_work_submitted: u64 = 0,
    irq_work_dropped: u64 = 0,
    irq_generation: u64 = 0,
    irq_pending_status: u16 = 0,
    work_pending: bool = false,
    work_handles: [WORK_HANDLE_CAPACITY]u32 = .{0} ** WORK_HANDLE_CAPACITY,
    work_reap_gate: bool = false,
    status_stopped: bool = false,
    status_submitters: u32 = 0,
    synchronous_stop: bool = false,
    output_epoch: u64 = 1,
    idle_close: idle_drain.State = .{},
    idle_close_handle: u32 = 0,
    idle_close_result: enum { none, pending, success, failed } = .none,
    idle_close_epoch: idle_drain.Identity = .{ .output = 0, .reset = 0, .pci = 0 },
    recovery_pending: bool = false,
    resampler_state: pcm.ResamplerState = .{},
};

var state: State = .{};

// 0.56.40: hz-neutrale Laufzeit-Umrechnung (R4D kennt DEFAULT_HZ nicht
// comptime; timerFrequency liefert die echte Tickrate).
fn msTicks(ctx: *const r4os.r4dev.DriverContext, ms: u64) u64 {
    const freq = @as(u64, ctx.timerFrequency());
    if (freq == 0) return @max(1, ms / 10);
    return @max(1, (ms * freq) / 1000);
}

export fn ac97_init(api: *const r4os.r4dev.DriverApi) callconv(.c) i32 {
    state = .{ .api = api };
    var ctx = context();
    if (!ctx.apiCompatible() or api.version < r4os.abi.driver_api_continuation_work_version) return -10;
    ctx.logInfo("AC97.R4D init");

    const info = findDevice(&ctx) orelse {
        ctx.logWarn("AC97.R4D device not found");
        return -1;
    };
    state.info = info;
    logDevice(&ctx, info);

    const nam_bar = ctx.pciReadBar(info, 0);
    const nabm_bar = ctx.pciReadBar(info, 1);
    if ((nam_bar & 1) == 0 or (nabm_bar & 1) == 0) {
        ctx.logError("AC97.R4D expected IO BARs missing");
        return -2;
    }

    state.nam_port = @truncate(nam_bar & 0xFFFC);
    state.nabm_port = @truncate(nabm_bar & 0xFFFC);
    if (state.nam_port == 0 or state.nabm_port == 0) {
        ctx.logError("AC97.R4D IO base is zero");
        return -3;
    }
    logIoPorts(&ctx);

    if (ctx.pciEnableBusMaster(info, r4os.abi.pci_enable_io_space) != 0) {
        ctx.logError("AC97.R4D bus master enable failed");
        return -4;
    }

    if (!allocDmaState(&ctx)) {
        ctx.logError("AC97.R4D DMA allocation failed");
        _ = shutdownHardware(&ctx);
        return -5;
    }

    codecReset(&ctx);
    if (!resetPlayback(&ctx)) {
        ctx.logError("AC97.R4D playback reset failed");
        _ = shutdownHardware(&ctx);
        return -7;
    }
    if (!setupInterrupts(&ctx)) {
        ctx.logError("AC97.R4D interrupt setup failed");
        _ = shutdownHardware(&ctx);
        return -8;
    }
    @atomicStore(bool, &state.present, true, .release);
    if (!registerPlaybackBackend(&ctx)) {
        ctx.logError("AC97.R4D audio backend register failed");
        _ = shutdownHardware(&ctx);
        return -6;
    }
    state.initialized = true;
    ctx.logInfo("AC97.R4D playback backend ready");
    return 0;
}

export fn ac97_shutdown() callconv(.c) i32 {
    var ctx = context();
    ctx.logInfo("AC97.R4D shutdown");
    if (!shutdownHardware(&ctx)) return -1;
    return if (unregisterPlaybackBackend(&ctx)) 0 else -2;
}

fn findDevice(ctx: *const r4os.r4dev.DriverContext) ?r4os.abi.PciDeviceInfo {
    var info: r4os.abi.PciDeviceInfo = .{};
    const found = ctx.pciFindByClass(CLASS_MULTIMEDIA, SUBCLASS_AUDIO, 0, &info);
    if (found < 0) return null;
    return info;
}

fn setupInterrupts(ctx: *const r4os.r4dev.DriverContext) bool {
    state.irq_registered = false;
    state.irq_mode = 0;
    state.irq_route_count = 0;
    state.irq_active_route = 0xFF;
    state.irq_routes = .{0xFF} ** IRQ_ROUTE_CAPACITY;
    disableInterrupts(ctx);

    const msi_irq = ctx.pciEnableMsi(state.info);
    if (msi_irq >= 0) {
        state.irq_mode = 2;
        if (msi_irq < 32) {
            const route: u8 = @intCast(msi_irq);
            if (ctx.irqRegister(route, irqHandler, @intFromPtr(&state), r4os.abi.irq_flag_msi) == 0) {
                state.irq_routes[0] = route;
                state.irq_route_count = 1;
                state.irq_registered = true;
            }
        }
        if (!state.irq_registered) {
            if (ctx.pciDisableMsi(state.info) != 0) return false;
            state.irq_mode = 0;
        }
    }

    if (!state.irq_registered) {
        // PCI Line is a legacy PIC assignment, not an ACPI _PRT/GSI result.
        // The board configuration must supply the exact INTx route.
        if (configuredIntxRoute(ctx)) |route| {
            _ = registerIrqRoute(ctx, route);
        } else {
            ctx.logError("AC97.R4D INTx needs a valid PCI pin and OPTION AC97 intx-gsi=<0..31>");
        }
        if (state.irq_route_count > 0) {
            state.irq_registered = true;
            state.irq_mode = 1;
        }
    }
    if (!state.irq_registered) return false;

    ctx.portOutw(state.nabm_port + PO_SR, SR_CLEAR);
    ctx.portOutb(state.nabm_port + PO_CR, (ctx.portInb(state.nabm_port + PO_CR) & ~CR_RUN) | CR_IRQ_ENABLE);
    return true;
}

fn configuredIntxRoute(ctx: *const r4os.r4dev.DriverContext) ?u8 {
    if (state.info.interrupt_pin < 1 or state.info.interrupt_pin > 4) return null;
    const value = std.mem.span(ctx.getOption("AC97", "intx-gsi"));
    if (value.len == 0 or value.len > 2) return null;
    var route: u8 = 0;
    for (value) |digit| {
        if (digit < '0' or digit > '9') return null;
        route = route * 10 + (digit - '0');
    }
    return if (route < 32) route else null;
}

fn registerIrqRoute(ctx: *const r4os.r4dev.DriverContext, route: u8) bool {
    if (route >= 32 or state.irq_route_count >= state.irq_routes.len) return false;
    var index: usize = 0;
    while (index < state.irq_route_count) : (index += 1) {
        if (state.irq_routes[index] == route) return true;
    }
    if (ctx.irqRegister(route, irqHandler, @intFromPtr(&state), r4os.abi.irq_flag_shared | r4os.abi.irq_flag_level_low) != 0) return false;
    state.irq_routes[state.irq_route_count] = route;
    state.irq_route_count += 1;
    return true;
}

fn disableInterrupts(ctx: *const r4os.r4dev.DriverContext) void {
    if (state.nabm_port == 0) return;
    ctx.portOutb(state.nabm_port + PO_CR, ctx.portInb(state.nabm_port + PO_CR) & ~CR_IRQ_ENABLE);
    ctx.portOutw(state.nabm_port + PO_SR, SR_CLEAR);
}

fn unregisterInterrupts(ctx: *const r4os.r4dev.DriverContext) bool {
    const used_msi = state.irq_mode == 2;
    var remaining: usize = 0;
    var index: usize = 0;
    while (index < state.irq_route_count) : (index += 1) {
        const route = state.irq_routes[index];
        if (route >= 32 or ctx.irqUnregister(route, irqHandler, @intFromPtr(&state)) != 0) {
            state.irq_routes[remaining] = route;
            remaining += 1;
        }
    }
    @memset(state.irq_routes[remaining..], 0xFF);
    state.irq_route_count = remaining;
    state.irq_registered = remaining != 0;
    if (remaining != 0) return false;
    if (used_msi and ctx.pciDisableMsi(state.info) != 0) return false;
    state.irq_mode = 0;
    return true;
}

fn irqHandler(irq: u8, raw_context: usize) callconv(.c) u32 {
    const s: *State = @ptrFromInt(raw_context);
    if (!@atomicLoad(bool, &s.present, .acquire) or s.nabm_port == 0) return 0;
    const ctx = r4os.r4dev.DriverContext.init(s.api);
    const status = ctx.portInw(s.nabm_port + PO_SR);
    const pending = status & SR_CLEAR;
    if (pending == 0) {
        _ = @atomicRmw(u64, &s.irq_unhandled, .Add, 1, .acq_rel);
        return 0;
    }

    _ = @atomicRmw(u64, &s.irq_count, .Add, 1, .acq_rel);
    @atomicStore(u8, &s.irq_active_route, irq, .release);
    _ = @atomicRmw(u16, &s.irq_pending_status, .Or, pending, .acq_rel);
    ctx.portOutw(s.nabm_port + PO_SR, pending);
    _ = @atomicRmw(u64, &s.irq_generation, .Add, 1, .acq_rel);
    if (!@atomicLoad(bool, &s.shutting_down, .acquire)) scheduleStatusWork(s);
    _ = @atomicRmw(u64, &s.irq_handled, .Add, 1, .acq_rel);
    return r4os.abi.irq_result_handled;
}

fn scheduleStatusWork(s: *State) void {
    if (@atomicLoad(bool, &s.status_stopped, .acquire)) return;
    _ = @atomicRmw(u32, &s.status_submitters, .Add, 1, .acq_rel);
    defer _ = @atomicRmw(u32, &s.status_submitters, .Sub, 1, .release);
    // Retirement closes admission before observing this in-flight count.
    if (@atomicLoad(bool, &s.status_stopped, .acquire)) return;
    if (@atomicRmw(bool, &s.work_pending, .Xchg, true, .acq_rel)) return;
    const ctx = r4os.r4dev.DriverContext.init(s.api);
    releaseCompletedWork(&ctx);
    var free_index: ?usize = null;
    for (&s.work_handles, 0..) |*stored, index| {
        if (@atomicLoad(u32, stored, .acquire) == 0) {
            free_index = index;
            break;
        }
    }
    const index = free_index orelse {
        _ = @atomicRmw(u64, &s.irq_work_dropped, .Add, 1, .acq_rel);
        @atomicStore(bool, &s.work_pending, false, .release);
        return;
    };

    const budget_ticks = @min(r4os.abi.driver_work_deadline_max_budget_ticks, msTicks(&ctx, REFILL_BUDGET_MS));
    const request = r4os.abi.DriverWorkRequest{
        .handler = statusWork,
        .context = @intFromPtr(s),
        .flags = r4os.abi.driver_work_flag_from_irq,
        .serial_key = @intFromPtr(s),
        .deadline_tick = ctx.tickCount() +| msTicks(&ctx, REFILL_DEADLINE_MS),
        .budget_ticks = @max(@as(u64, 1), budget_ticks),
    };
    var handle: u32 = 0;
    if (ctx.workSubmitRequest(&request, &handle) != 0 or handle == 0) {
        _ = @atomicRmw(u64, &s.irq_work_dropped, .Add, 1, .acq_rel);
        @atomicStore(bool, &s.work_pending, false, .release);
        return;
    }
    @atomicStore(u32, &s.work_handles[index], handle, .release);
    _ = @atomicRmw(u64, &s.irq_work_submitted, .Add, 1, .acq_rel);
}

fn statusWork(raw_context: usize) callconv(.c) i32 {
    const s: *State = @ptrFromInt(raw_context);
    const ctx = r4os.r4dev.DriverContext.init(s.api);
    releaseCompletedWork(&ctx);
    const observed_generation = @atomicLoad(u64, &s.irq_generation, .acquire);
    var completed = false;
    if (!@atomicLoad(bool, &s.shutting_down, .acquire) and !@atomicLoad(bool, &s.status_stopped, .acquire) and tryAcquireStream()) {
        defer releaseStream();
        completed = true;
        const pending_status = @atomicRmw(u16, &s.irq_pending_status, .Xchg, 0, .acq_rel);
        const snapshot = ctx.portInl(s.nabm_port + PO_CIV);
        const civ: usize = @intCast(snapshot & 0x1F);
        const current_status: u16 = @truncate(snapshot >> 16);
        serviceStatusSnapshot(&ctx, civ, current_status | pending_status);
        if (@atomicRmw(bool, &s.recovery_pending, .Xchg, false, .acq_rel)) {
            if (resetPlayback(&ctx)) {
                s.recovery_count +%= 1;
            } else {
                s.error_count +%= 1;
            }
        }
    }
    if (work_gate.finishPass(&s.work_pending, &s.irq_generation, observed_generation, &s.status_stopped, completed) == .resubmit) scheduleStatusWork(s);
    return 0;
}

fn releaseCompletedWork(ctx: *const r4os.r4dev.DriverContext) void {
    if (!tryAcquireReaper()) return;
    defer releaseReaper();
    for (&state.work_handles) |*stored| {
        const handle = @atomicLoad(u32, stored, .acquire);
        if (handle == 0) continue;
        var status: r4os.abi.DriverCompletionStatus = .{};
        if (ctx.completionStatus(handle, &status) != 0) continue;
        if (status.state != r4os.abi.driver_work_state_completed and status.state != r4os.abi.driver_work_state_cancelled) continue;
        if (ctx.completionRelease(handle) == 0) @atomicStore(u32, stored, 0, .release);
    }
}

fn releaseDriverWork(ctx: *const r4os.r4dev.DriverContext) bool {
    @atomicStore(bool, &state.status_stopped, true, .release);
    @atomicStore(bool, &state.work_pending, false, .release);
    @atomicStore(u16, &state.irq_pending_status, 0, .release);
    var quiesced = true;
    const until = ctx.tickCount() +| msTicks(ctx, PLAYBACK_WAIT_MS);
    while (@atomicLoad(u32, &state.status_submitters, .acquire) != 0) {
        if (ctx.tickCount() >= until) return false;
        ctx.waitTicks(1);
    }
    for (&state.work_handles) |*stored| if (!waitAndReleaseWork(ctx, stored)) {
        quiesced = false;
    };
    if (!waitAndReleaseWork(ctx, &state.idle_close_handle)) quiesced = false;
    return quiesced;
}

fn tryAcquireReaper() bool {
    return !@atomicRmw(bool, &state.work_reap_gate, .Xchg, true, .acq_rel);
}

fn releaseReaper() void {
    @atomicStore(bool, &state.work_reap_gate, false, .release);
}

// No stream owner or reaper gate spans completionWait: its worker can need
// those owners to terminate. A concurrent successful reaper leaves stored=0.
fn waitAndReleaseWork(ctx: *const r4os.r4dev.DriverContext, stored: *u32) bool {
    const until = ctx.tickCount() +| msTicks(ctx, PLAYBACK_WAIT_MS);
    while (true) {
        if (tryAcquireReaper()) {
            const handle = @atomicLoad(u32, stored, .acquire);
            if (handle == 0) {
                releaseReaper();
                return true;
            }
            var status: r4os.abi.DriverCompletionStatus = .{};
            const rc = ctx.completionStatus(handle, &status);
            if (rc != 0) {
                releaseReaper();
                return false;
            }
            if (status.state == r4os.abi.driver_work_state_completed or status.state == r4os.abi.driver_work_state_cancelled) {
                const released = ctx.completionRelease(handle) == 0;
                if (released) @atomicStore(u32, stored, 0, .release);
                releaseReaper();
                return released;
            }
            if (status.state == r4os.abi.driver_work_state_queued) _ = ctx.workCancel(handle);
            releaseReaper();
            if (ctx.tickCount() >= until) return false;
            var result: i32 = 0;
            _ = ctx.completionWait(handle, until -| ctx.tickCount(), &result);
        } else {
            if (ctx.tickCount() >= until) return false;
            ctx.waitTicks(1);
        }
    }
}

fn allocDmaState(ctx: *const r4os.r4dev.DriverContext) bool {
    if (ctx.allocDmaRegionConstrained(@intCast(@sizeOf(BdlEntry) * BDL_ENTRY_COUNT), 16, 0xFFFF_FFFF, &state.bdl) != 0) return false;
    if (state.bdl.phys_addr == 0 or state.bdl.virt_addr == 0) return false;

    var i: usize = 0;
    while (i < DMA_BUFFER_COUNT) : (i += 1) {
        if (ctx.allocDmaRegionConstrained(MAX_DMA_BYTES, 16, 0xFFFF_FFFF, &state.dma[i]) != 0) return false;
        if (state.dma[i].phys_addr == 0 or state.dma[i].virt_addr == 0) return false;
    }

    clearBdl();
    logDma(ctx);
    return true;
}

fn clearBdl() void {
    if (state.bdl.virt_addr == 0) return;
    const bdl: [*]volatile BdlEntry = @ptrFromInt(state.bdl.virt_addr);
    var i: usize = 0;
    while (i < BDL_ENTRY_COUNT) : (i += 1) {
        bdl[i] = .{ .addr = 0, .samples = 0, .control = 0 };
    }
}

fn codecReset(ctx: *const r4os.r4dev.DriverContext) void {
    if (state.nam_port == 0) return;
    _ = ctx.portInw(state.nam_port + NAM_RESET);
    ctx.portOutw(state.nam_port + NAM_MASTER_VOLUME, 0x0000);
    ctx.portOutw(state.nam_port + NAM_PCM_OUT_VOLUME, 0x0000);
    const ext = ctx.portInw(state.nam_port + NAM_EXT_AUDIO_CTRL);
    ctx.portOutw(state.nam_port + NAM_EXT_AUDIO_CTRL, ext | 0x0001);
    ctx.portOutw(state.nam_port + NAM_PCM_FRONT_RATE, TARGET_RATE);
}

fn registerPlaybackBackend(ctx: *const r4os.r4dev.DriverContext) bool {
    state.backend = .{
        .base = .{
            .base = .{
                .version = r4os.abi.audio_backend_idle_version,
                .size = @sizeOf(r4os.r4dev.AudioOutputIdleBackend),
                .context = &state,
                .formats = r4os.abi.audio_backend_format_s16le | r4os.abi.audio_backend_format_u8,
                .min_rate = MIN_RATE,
                .max_rate = MAX_RATE,
                .preferred_rate = pcm.TARGET_RATE,
                .max_channels = pcm.TARGET_CHANNELS,
                .write_pcm = writePcm,
                .stop = stopPlaybackBackend,
                .shutdown = shutdownBackend,
                .status = backendStatus,
            },
            .outputs = .{ .query = queryOutput, .select = selectOutput, .active = activeOutput },
        },
        .idle = idlePlaybackBackend,
    };
    const rc = ctx.registerAudioOutputIdle("AC97", &state.backend);
    state.last_result = rc;
    if (rc != 0) {
        state.error_count += 1;
        return false;
    }
    state.backend_registered = true;
    state.last_result = ctx.registerAudioOutputEpoch("AC97", outputEpoch);
    if (state.last_result != 0) {
        _ = unregisterPlaybackBackend(ctx);
        return false;
    }
    return true;
}

fn queryOutput(_: u64, index: u32, out: *r4os.abi.AudioOutputInfo) callconv(.c) i32 {
    out.* = .{};
    if (index != 0) return 0;
    @memcpy(out.id[0..4], "AC97");
    @memcpy(out.name[0..4], "AC97");
    out.availability = if (@atomicLoad(bool, &state.present, .acquire) and !@atomicLoad(bool, &state.shutting_down, .acquire)) r4os.abi.audio_output_available else r4os.abi.audio_output_unavailable;
    out.preferred_rate = pcm.TARGET_RATE;
    out.channels = pcm.TARGET_CHANNELS;
    out.format = pcm.FORMAT_S16LE;
    return 1;
}

fn selectOutput(_: u64, index: u32) callconv(.c) i32 {
    return if (index == 0 and activeOutput(0) == 0) 0 else -1;
}

fn activeOutput(_: u64) callconv(.c) i32 {
    return if (@atomicLoad(bool, &state.present, .acquire) and !@atomicLoad(bool, &state.shutting_down, .acquire)) 0 else -1;
}

fn outputEpoch(_: u64, out: *r4os.abi.AudioOutputEpoch) callconv(.c) i32 {
    // One immutable connector during this registration. Shutdown is terminal,
    // never a second valid generation pretending to be the live connector.
    if (!@atomicLoad(bool, &state.present, .acquire) or @atomicLoad(bool, &state.shutting_down, .acquire)) return r4os.abi.service_api_result_busy;
    out.* = .{ .generation = 1, .count = 1, .active_index = 0 };
    return 1;
}

fn unregisterPlaybackBackend(ctx: *const r4os.r4dev.DriverContext) bool {
    if (!state.backend_registered) return true;
    if (ctx.unregisterAudioBackend("AC97") != 0) return false;
    state.backend_registered = false;
    return true;
}

fn acceptsPcmInput(rate: u32, channels: u16, format: u16) bool {
    if (rate < MIN_RATE or rate > MAX_RATE) return false;
    if (channels == 0 or channels > pcm.TARGET_CHANNELS) return false;
    return format == pcm.FORMAT_S16LE or format == pcm.FORMAT_U8;
}

fn writePcm(context_arg: ?*anyopaque, data: [*]const u8, len: u32, rate: u32, channels: u16, format: u16) callconv(.c) i32 {
    _ = context_arg;
    var ctx = context();
    const write_start = ctx.tickCount();
    if (!acceptsPcmInput(rate, channels, format)) return finishWrite(r4os.abi.service_api_result_invalid, write_start);
    if (!@atomicLoad(bool, &state.present, .acquire) or @atomicLoad(bool, &state.shutting_down, .acquire) or state.nabm_port == 0) return finishWrite(-1, write_start);
    releaseCompletedWork(&ctx);
    if (!tryAcquireStream()) return finishWrite(r4os.abi.service_api_result_busy, write_start);
    defer {
        releaseStream();
        if (!@atomicLoad(bool, &state.status_stopped, .acquire) and @atomicLoad(u16, &state.irq_pending_status, .acquire) != 0) scheduleStatusWork(&state);
    }
    if (@atomicLoad(bool, &state.shutting_down, .acquire)) return finishWrite(-1, write_start);
    if (@atomicLoad(bool, &state.synchronous_stop, .acquire)) return finishWrite(r4os.abi.service_api_result_busy, write_start);
    if (state.idle_close_result != .none and state.output_epoch == @import("std").math.maxInt(u64)) return finishWrite(-1, write_start);
    const input = data[0..@as(usize, @intCast(len))];
    if (pcm.outputFrameCount(input.len, rate, channels, format) == 0) return finishWrite(-2, write_start);
    const output_frames = pendingOutputFrames(input.len, rate, channels, format) orelse return finishWrite(-2, write_start);
    const required_buffers = dmaBuffersForFrames(output_frames) orelse return finishWrite(r4os.abi.service_api_result_full, write_start);
    if (required_buffers > DMA_BUFFER_COUNT) return finishWrite(r4os.abi.service_api_result_full, write_start);

    serviceStatus(&ctx);
    if (required_buffers > state.queue.available()) return finishWrite(r4os.abi.service_api_result_busy, write_start);

    const resampler_before = state.resampler_state;
    state.resampler_state.beginChunk(rate, channels, format);
    if (output_frames == 0) {
        var scratch: [pcm.TARGET_FRAME_BYTES]u8 = undefined;
        const converted = pcm.convertStreamingToStereoS16(&state.resampler_state, input, rate, channels, format, &scratch);
        if (converted != 0 or !state.resampler_state.chunk_done) {
            state.resampler_state = resampler_before;
            return finishWrite(-3, write_start);
        }
        state.last_source_rate = rate;
        state.last_source_channels = channels;
        state.last_source_format = format;
        state.last_output_frames = 0;
        state.write_count +%= 1;
        acceptNewPcm();
        return finishWrite(0, write_start);
    }
    var lengths: [DMA_BUFFER_COUNT]usize = .{0} ** DMA_BUFFER_COUNT;
    var prepared: usize = 0;
    var output_bytes: usize = 0;
    while (!state.resampler_state.chunk_done) {
        const descriptor = state.queue.descriptorAt(prepared) orelse {
            state.resampler_state = resampler_before;
            return finishWrite(r4os.abi.service_api_result_busy, write_start);
        };
        const out = dmaSlice(descriptor) orelse {
            state.resampler_state = resampler_before;
            return finishWrite(-3, write_start);
        };
        // The SDK copies native 48-kHz stereo S16 blocks directly into the
        // reserved DMA slot; other formats retain the streaming converter.
        const converted = pcm.convertStreamingToStereoS16(&state.resampler_state, input, rate, channels, format, out);
        if (converted == 0) {
            if (state.resampler_state.chunk_done) break;
            state.resampler_state = resampler_before;
            return finishWrite(-4, write_start);
        }
        lengths[prepared] = converted;
        prepared += 1;
        output_bytes += converted;
    }

    if (prepared != 0 and !publishDmaBuffers(&ctx, lengths[0..prepared])) {
        state.resampler_state = resampler_before;
        return finishWrite(-5, write_start);
    }
    state.last_source_rate = rate;
    state.last_source_channels = channels;
    state.last_source_format = format;
    state.last_output_frames = output_bytes / pcm.TARGET_FRAME_BYTES;
    state.converted_frame_count +%= state.last_output_frames;
    state.write_count +%= 1;
    return finishWrite(0, write_start);
}

fn dmaBuffersForFrames(frames: usize) ?usize {
    if (frames > (@as(usize, @intCast(MAX_DMA_BYTES)) * DMA_BUFFER_COUNT) / pcm.TARGET_FRAME_BYTES) return null;
    const bytes = frames * pcm.TARGET_FRAME_BYTES;
    const buffer_bytes: usize = @intCast(MAX_DMA_BYTES);
    return (bytes + buffer_bytes - 1) / buffer_bytes;
}

fn pendingOutputFrames(input_len: usize, rate: u32, channels: u16, format: u16) ?usize {
    const frame_bytes = pcm.sourceFrameBytes(channels, format) orelse return null;
    const input_frames = input_len / frame_bytes;
    const same_format = state.resampler_state.rate == rate and state.resampler_state.channels == channels and state.resampler_state.format == format;
    const phase = if (same_format) state.resampler_state.phase_q16 else 0;
    return queue_state.plannedOutputFrames(input_frames, rate, pcm.TARGET_RATE, phase);
}

fn stopPlaybackBackend(context_arg: ?*anyopaque) callconv(.c) i32 {
    _ = context_arg;
    var ctx = context();
    const was_stopped = @atomicLoad(bool, &state.status_stopped, .acquire);
    @atomicStore(bool, &state.synchronous_stop, true, .release);
    @atomicStore(bool, &state.status_stopped, true, .release);
    if (!acquireStream(&ctx, PLAYBACK_WAIT_MS)) {
        @atomicStore(bool, &state.synchronous_stop, false, .release);
        @atomicStore(bool, &state.status_stopped, was_stopped, .release);
        if (!was_stopped and @atomicLoad(u16, &state.irq_pending_status, .acquire) != 0) scheduleStatusWork(&state);
        return setLastResult(r4os.abi.service_api_result_busy);
    }
    cancelIdleClose();
    const stopped = stopPlayback(&ctx, true);
    releaseStream();
    if (!releaseDriverWork(&ctx)) return setLastResult(-1);
    if (stopped) @atomicStore(bool, &state.synchronous_stop, false, .release);
    return setLastResult(if (stopped) 0 else -1);
}

fn cancelIdleClose() void {
    state.idle_close.reset();
    state.idle_close_result = .none;
}

// Called only after a complete successful source acceptance, under stream.
// Invalid/Busy writes leave the previous close intention and epoch intact.
fn acceptNewPcm() void {
    if (state.idle_close_result != .none) {
        state.output_epoch += 1; // overflow rejected before conversion
        cancelIdleClose();
    }
    @atomicStore(bool, &state.status_stopped, false, .release);
}

const IdleCloseOwner = struct {
    ctx: *const r4os.r4dev.DriverContext,
    pub fn identity(_: *@This()) idle_drain.Identity {
        return .{ .output = state.output_epoch, .reset = state.reset_count, .pci = (@as(u32, state.info.bus) << 8) | (@as(u32, state.info.device) << 3) | state.info.function };
    }
    pub fn now(self: *@This()) u64 {
        return self.ctx.tickCount();
    }
    pub fn pump(self: *@This()) bool {
        const pending = @atomicRmw(u16, &state.irq_pending_status, .Xchg, 0, .acq_rel);
        const snapshot = self.ctx.portInl(state.nabm_port + PO_CIV);
        const sr: u16 = @truncate(snapshot >> 16);
        serviceStatusSnapshot(self.ctx, @intCast(snapshot & 0x1F), sr | pending);
        return state.queue.pending == 0 and (sr & SR_DCH) != 0;
    }
    pub fn quiet(self: *@This()) bool {
        @atomicStore(bool, &state.status_stopped, true, .release);
        return stopPlayback(self.ctx, false);
    }
    pub fn retire(self: *@This()) idle_drain.Retirement {
        if (@atomicLoad(u32, &state.status_submitters, .acquire) != 0 or !tryAcquireReaper()) return .pending;
        defer releaseReaper();
        for (&state.work_handles) |*stored| {
            const handle = @atomicLoad(u32, stored, .acquire);
            if (handle == 0) continue;
            var status: r4os.abi.DriverCompletionStatus = .{};
            if (self.ctx.completionStatus(handle, &status) != 0) return .failed;
            if (status.state == r4os.abi.driver_work_state_queued) _ = self.ctx.workCancel(handle);
            if (status.state != r4os.abi.driver_work_state_completed and status.state != r4os.abi.driver_work_state_cancelled) return .pending;
            if (self.ctx.completionRelease(handle) != 0) return .pending;
            @atomicStore(u32, stored, 0, .release);
        }
        // A cancelled queued status callback does not execute finishPass.
        // Restore the original Stop cleanup only after every actual ticket
        // and in-flight submitter has retired; future PCM can admit work.
        @atomicStore(bool, &state.work_pending, false, .release);
        @atomicStore(u16, &state.irq_pending_status, 0, .release);
        return .complete;
    }
};

// The existing continuation flag/result retains one ticket across bounded
// turns. No client pointer, sleeping lock or audio-deadline job is retained.
fn idleCloseWork(_: usize) callconv(.c) i32 {
    if (@atomicLoad(bool, &state.shutting_down, .acquire) or @atomicLoad(bool, &state.synchronous_stop, .acquire)) return 0;
    if (!tryAcquireStream()) return r4os.abi.driver_work_result_wait;
    defer releaseStream();
    if (state.idle_close_result != .pending) return 0;
    var ctx = context();
    var owner = IdleCloseOwner{ .ctx = &ctx };
    const result = state.idle_close.poll(&owner, msTicks(&ctx, PLAYBACK_WAIT_MS));
    if (result == .pending) return r4os.abi.driver_work_result_wait;
    if (result == .complete) {
        state.idle_close_epoch = owner.identity();
        state.idle_close_result = .success;
        return 0;
    }
    if (result == .drain_timeout) state.drain_timeout_count +%= 1;
    if (result != .changed) {
        @atomicStore(bool, &state.status_stopped, true, .release);
        // Preserve the original timeout's physical reset/drop attempt. A
        // failed quiet/reset never turns this failed Close into success.
        _ = stopPlayback(&ctx, false);
    }
    state.idle_close_result = .failed;
    _ = setLastResult(-1);
    return -1;
}

fn idlePlaybackBackend(_: ?*anyopaque) callconv(.c) i32 {
    if (!tryAcquireStream()) return r4os.abi.service_api_result_busy;
    defer releaseStream();
    if (@atomicLoad(bool, &state.shutting_down, .acquire) or @atomicLoad(bool, &state.synchronous_stop, .acquire)) return r4os.abi.service_api_result_busy;
    if (!tryAcquireReaper()) return r4os.abi.service_api_result_busy;
    defer releaseReaper();
    var ctx = context();
    var owner = IdleCloseOwner{ .ctx = &ctx };
    const handle = @atomicLoad(u32, &state.idle_close_handle, .acquire);
    if (handle != 0) {
        var status: r4os.abi.DriverCompletionStatus = .{};
        const rc = ctx.completionStatus(handle, &status);
        if (rc != 0) return setLastResult(-1);
        if (status.state != r4os.abi.driver_work_state_completed and status.state != r4os.abi.driver_work_state_cancelled) return r4os.abi.service_api_result_busy;
        if (ctx.completionRelease(handle) != 0) return r4os.abi.service_api_result_busy;
        @atomicStore(u32, &state.idle_close_handle, 0, .release);
        const result = state.idle_close_result;
        const same = @import("std").meta.eql(state.idle_close_epoch, owner.identity());
        cancelIdleClose();
        if (result == .failed) return -1; // already recorded by the autonomous worker
        if (result != .none) return setLastResult(if (result == .success and status.state == r4os.abi.driver_work_state_completed and status.result == 0 and same) 0 else -1);
    }
    state.idle_close_result = .pending;
    state.idle_close.start(owner.identity(), ctx.tickCount(), msTicks(&ctx, DRAIN_WAIT_MS));
    if (state.playback_started) state.drain_count +%= 1;
    var new_handle: u32 = 0;
    if (ctx.workSubmit(idleCloseWork, @intFromPtr(&state), r4os.abi.driver_work_flag_continuation, &new_handle) != 0 or new_handle == 0) {
        cancelIdleClose();
        return r4os.abi.service_api_result_busy;
    }
    @atomicStore(u32, &state.idle_close_handle, new_handle, .release);
    return r4os.abi.service_api_result_busy;
}

fn shutdownBackend(context_arg: ?*anyopaque) callconv(.c) i32 {
    _ = context_arg;
    var ctx = context();
    return setLastResult(if (shutdownHardware(&ctx)) 0 else -1);
}

fn backendStatus(context_arg: ?*anyopaque, out: *r4os.abi.AudioBackendStatus) callconv(.c) i32 {
    _ = context_arg;
    if (!tryAcquireStream()) {
        out.* = .{};
        return r4os.abi.service_api_result_busy;
    }
    defer releaseStream();
    var ctx = context();
    serviceStatus(&ctx);
    out.* = .{
        .active = if (@atomicLoad(bool, &state.present, .acquire) and state.backend_registered) 1 else 0,
        .writes = state.write_count,
        .underruns = state.underrun_count,
        .errors = state.error_count + state.timeout_count + state.fifo_error_count + state.drain_timeout_count + state.irq_work_dropped,
        .last_result = state.last_result,
        .reserved = 0,
        .refills = state.refill_count,
        .silence_refills = 0,
        .buffer_bytes = @as(u64, @intCast(DMA_BUFFER_COUNT)) * @as(u64, MAX_DMA_BYTES),
        .queued_buffers = @intCast(state.queue.pending),
        .last_buffer_bytes = @intCast(state.last_output_frames * pcm.TARGET_FRAME_BYTES),
        .last_write_ticks = state.write_last_ticks,
        .max_write_ticks = state.write_max_ticks,
        .total_write_ticks = state.write_total_ticks,
        .last_refill_ticks = state.refill_last_ticks,
        .max_refill_ticks = state.refill_max_ticks,
        .total_refill_ticks = state.refill_total_ticks,
    };
    return 0;
}

fn publishDmaBuffers(ctx: *const r4os.r4dev.DriverContext, lengths: []const usize) bool {
    if (lengths.len == 0 or state.bdl.virt_addr == 0 or lengths.len > state.queue.available()) return false;
    serviceStatus(ctx);
    if (lengths.len > state.queue.available()) return false;
    const refill_start = ctx.tickCount();
    const bdl: [*]volatile BdlEntry = @ptrFromInt(state.bdl.virt_addr);
    var offset: usize = 0;
    while (offset < lengths.len) : (offset += 1) {
        const descriptor = state.queue.descriptorAt(offset) orelse return false;
        const dma_index = descriptor % DMA_BUFFER_COUNT;
        const len = lengths[offset];
        if (len < pcm.TARGET_FRAME_BYTES or len > MAX_DMA_BYTES or (len % 2) != 0 or state.dma[dma_index].phys_addr == 0) return false;
        bdl[descriptor] = .{
            .addr = @truncate(state.dma[dma_index].phys_addr),
            .samples = @intCast(len / 2),
            .control = BDL_IOC,
        };
    }

    const last_descriptor = state.queue.descriptorAt(lengths.len - 1) orelse return false;
    if (!state.queue.commit(lengths.len)) return false;
    acceptNewPcm();
    ctx.portOutb(state.nabm_port + PO_LVI, @intCast(last_descriptor));
    ctx.portOutb(state.nabm_port + PO_CR, ctx.portInb(state.nabm_port + PO_CR) | CR_IRQ_ENABLE | CR_RUN);
    state.playback_started = true;
    state.refill_count +%= lengths.len;
    recordTickStat(&state.refill_total_ticks, &state.refill_max_ticks, &state.refill_last_ticks, refill_start);
    return true;
}

fn resetPlayback(ctx: *const r4os.r4dev.DriverContext) bool {
    if (state.nabm_port == 0) return true;
    state.reset_count += 1;
    ctx.portOutb(state.nabm_port + PO_CR, ctx.portInb(state.nabm_port + PO_CR) & ~CR_RUN);
    ctx.portOutb(state.nabm_port + PO_CR, CR_RESET);
    var guard: u32 = 0;
    while ((ctx.portInb(state.nabm_port + PO_CR) & CR_RESET) != 0 and guard < 100000) : (guard += 1) {}
    if ((ctx.portInb(state.nabm_port + PO_CR) & CR_RESET) != 0) {
        state.timeout_count += 1;
        return false;
    }
    ctx.portOutw(state.nabm_port + PO_SR, SR_CLEAR);
    ctx.portOutb(state.nabm_port + PO_CR, if (state.irq_registered) CR_IRQ_ENABLE else 0);
    state.last_status = ctx.portInw(state.nabm_port + PO_SR);
    state.playback_started = false;
    state.dch_active = (state.last_status & SR_DCH) != 0;
    state.queue.reset();
    state.resampler_state.reset();
    @atomicStore(bool, &state.recovery_pending, false, .release);
    clearBdl();
    if (state.bdl.phys_addr != 0) ctx.portOutl(state.nabm_port + PO_BDBAR, @truncate(state.bdl.phys_addr));
    return true;
}

fn stopPlayback(ctx: *const r4os.r4dev.DriverContext, drain: bool) bool {
    if (state.nabm_port == 0) return true;
    var drained = true;
    if (@atomicLoad(bool, &state.present, .acquire)) {
        serviceStatus(ctx);
        if (drain) {
            drained = drainPlayback(ctx);
        } else {
            state.dropped_buffer_count +%= state.queue.pending;
        }
    }
    const reset = resetPlayback(ctx);
    state.stop_count += 1;
    return drained and reset;
}

fn shutdownHardware(ctx: *const r4os.r4dev.DriverContext) bool {
    @atomicStore(bool, &state.shutting_down, true, .release);
    @atomicStore(bool, &state.synchronous_stop, true, .release);
    @atomicStore(bool, &state.status_stopped, true, .release);
    {
        if (!acquireStream(ctx, PLAYBACK_WAIT_MS)) return false;
        defer releaseStream();
        cancelIdleClose();
        const stopped = stopPlayback(ctx, true);
        if (!stopped and state.playback_started) return false;
        disableInterrupts(ctx);
        if (!unregisterInterrupts(ctx)) return false;
    }
    if (!releaseDriverWork(ctx)) return false;
    clearBdl();

    var i: usize = 0;
    while (i < DMA_BUFFER_COUNT) : (i += 1) {
        if (state.dma[i].phys_addr != 0) ctx.freeDmaRegion(&state.dma[i]);
    }
    if (state.bdl.phys_addr != 0) ctx.freeDmaRegion(&state.bdl);
    state.initialized = false;
    @atomicStore(bool, &state.present, false, .release);
    state.playback_started = false;
    state.queue.reset();
    return true;
}

fn drainPlayback(ctx: *const r4os.r4dev.DriverContext) bool {
    if (!state.playback_started) return true;
    state.drain_count += 1;
    const deadline = ctx.tickCount() + msTicks(ctx, DRAIN_WAIT_MS);
    while (ctx.tickCount() <= deadline) {
        serviceStatus(ctx);
        const sr = ctx.portInw(state.nabm_port + PO_SR);
        if (state.queue.pending == 0 and (sr & SR_DCH) != 0) return true;
        ctx.waitTicks(1);
    }
    state.drain_timeout_count += 1;
    return false;
}

fn serviceStatus(ctx: *const r4os.r4dev.DriverContext) void {
    if (!@atomicLoad(bool, &state.present, .acquire) or state.nabm_port == 0) return;
    const snapshot = ctx.portInl(state.nabm_port + PO_CIV);
    const civ: usize = @intCast(snapshot & 0x1F);
    const sr: u16 = @truncate(snapshot >> 16);
    serviceStatusSnapshot(ctx, civ, sr);
}

fn serviceStatusSnapshot(ctx: *const r4os.r4dev.DriverContext, civ: usize, sr: u16) void {
    _ = state.queue.observe(civ, (sr & SR_CELV) != 0);
    state.last_status = sr;
    if ((sr & SR_BCIS) != 0) state.status_irq_count += 1;
    if ((sr & SR_LVBCI) != 0) state.normal_completion_count += 1;
    if ((sr & SR_FIFOE) != 0) {
        state.fifo_error_count += 1;
        state.underrun_count += 1;
        @atomicStore(bool, &state.recovery_pending, true, .release);
    }
    const halted = (sr & SR_DCH) != 0;
    if (halted and !state.dch_active) {
        state.dch_count += 1;
    }
    state.dch_active = halted;
    if ((sr & SR_CLEAR) != 0) ctx.portOutw(state.nabm_port + PO_SR, sr & SR_CLEAR);
}

fn dmaSlice(index: usize) ?[]u8 {
    if (index >= BDL_ENTRY_COUNT) return null;
    const buffer = state.dma[index % DMA_BUFFER_COUNT];
    if (buffer.virt_addr == 0 or buffer.bytes == 0) return null;
    const bytes = if (buffer.bytes < MAX_DMA_BYTES) buffer.bytes else MAX_DMA_BYTES;
    const ptr: [*]u8 = @ptrFromInt(buffer.virt_addr);
    return ptr[0..@as(usize, @intCast(bytes))];
}

fn tryAcquireStream() bool {
    return !@atomicRmw(bool, &state.stream_lock, .Xchg, true, .acq_rel);
}

fn acquireStream(ctx: *const r4os.r4dev.DriverContext, timeout_ms: u64) bool {
    if (tryAcquireStream()) return true;
    const deadline = ctx.tickCount() + msTicks(ctx, timeout_ms);
    while (ctx.tickCount() < deadline) {
        ctx.waitTicks(1);
        if (tryAcquireStream()) return true;
    }
    return false;
}

fn releaseStream() void {
    @atomicStore(bool, &state.stream_lock, false, .release);
}

// Host-only API table adapter; the tests call the actual descriptor and
// callbacks. Native Work scheduling, DMA and device receipts stay separate.
const IdleCallbackProbe = struct {
    const a = r4os.abi;
    var api: a.DriverApi = undefined;
    var ticks: u64 = 100;
    var sr: u16 = 0;
    var civ: u8 = 0;
    var cr: u8 = 0;
    var waits: usize = 0;
    var submits: usize = 0;
    var last_flags: u32 = 0;
    var release_count: usize = 0;
    var released: [16]u32 = undefined;
    var fail_reset = false;
    var fail_release = false;
    var finish_on_wait = false;
    var slots: [32]a.DriverCompletionStatus = .{a.DriverCompletionStatus{}} ** 32;
    var bdl: [BDL_ENTRY_COUNT]BdlEntry = undefined;
    var dma: [DMA_BUFFER_COUNT][MAX_DMA_BYTES]u8 = undefined;
    fn reset() void {
        api = undefined;
        api.magic = a.driver_magic;
        api.version = a.driver_api_version;
        api.size = @sizeOf(a.DriverApi);
        api.tick_count = tick;
        api.timer_frequency = frequency;
        api.wait_ticks = wait;
        api.port_inb = inb;
        api.port_inw = inw;
        api.port_inl = inl;
        api.port_outb = outb;
        api.port_outw = outw;
        api.port_outl = outl;
        api.driver_work_submit = submit;
        api.driver_work_cancel = cancel;
        api.driver_completion_status = status;
        api.driver_completion_release = release;
        api.driver_completion_wait = completionWait;
        api.register_audio_output_backend = register;
        api.register_audio_output_epoch = registerEpoch;
        api.log_info = log;
        api.log_warn = log;
        api.log_error = log;
        ticks = 100;
        sr = 0;
        civ = 0;
        cr = CR_RUN;
        waits = 0;
        submits = 0;
        last_flags = 0;
        release_count = 0;
        fail_reset = false;
        fail_release = false;
        finish_on_wait = false;
        slots = .{a.DriverCompletionStatus{}} ** 32;
        state = .{ .api = &api, .present = true, .backend_registered = true, .nabm_port = 0x100, .reset_count = 1, .playback_started = true };
    }
    fn buffers() void {
        state.bdl = .{ .phys_addr = 0x1000, .virt_addr = @intFromPtr(&bdl), .bytes = @sizeOf(@TypeOf(bdl)) };
        for (&state.dma, 0..) |*buffer, index| buffer.* = .{ .phys_addr = 0x2000 + index * MAX_DMA_BYTES, .virt_addr = @intFromPtr(&dma[index]), .bytes = MAX_DMA_BYTES };
    }
    fn log(_: [*:0]const u8) callconv(.c) void {}
    fn tick() callconv(.c) u64 {
        return ticks;
    }
    fn frequency() callconv(.c) u32 {
        return 1000;
    }
    fn wait(value: u64) callconv(.c) void {
        waits += 1;
        ticks += value;
    }
    fn inb(_: u16) callconv(.c) u8 {
        return cr;
    }
    fn inw(_: u16) callconv(.c) u16 {
        return sr;
    }
    fn inl(_: u16) callconv(.c) u32 {
        return @as(u32, civ) | (@as(u32, sr) << 16);
    }
    fn outb(port: u16, value: u8) callconv(.c) void {
        if (port != state.nabm_port + PO_CR) return;
        cr = if ((value & CR_RESET) != 0 and !fail_reset) 0 else value;
        if ((value & CR_RUN) != 0) sr &= ~SR_DCH;
    }
    fn outw(_: u16, value: u16) callconv(.c) void {
        sr &= ~(value & SR_CLEAR);
    }
    fn outl(_: u16, _: u32) callconv(.c) void {}
    fn submit(handler: a.DriverWorkHandler, raw: usize, flags: u32, out: *u32) callconv(.c) i32 {
        std.debug.assert(@intFromPtr(handler) == @intFromPtr(&idleCloseWork) and raw == @intFromPtr(&state));
        submits += 1;
        last_flags = flags;
        const handle: u32 = @intCast(6 + submits);
        slots[handle] = .{ .handle = handle, .state = a.driver_work_state_queued };
        out.* = handle;
        return 0;
    }
    fn status(handle: u32, out: *a.DriverCompletionStatus) callconv(.c) i32 {
        if (handle >= slots.len or slots[handle].state == a.driver_work_state_free) return -1;
        out.* = slots[handle];
        return 0;
    }
    fn cancel(handle: u32) callconv(.c) i32 {
        if (slots[handle].state != a.driver_work_state_queued) return -1;
        slots[handle].state = a.driver_work_state_cancelled;
        slots[handle].result = a.driver_work_result_cancelled;
        return 0;
    }
    fn release(handle: u32) callconv(.c) i32 {
        if (fail_release or (slots[handle].state != a.driver_work_state_completed and slots[handle].state != a.driver_work_state_cancelled)) return -1;
        released[release_count] = handle;
        release_count += 1;
        slots[handle] = .{};
        return 0;
    }
    fn completionWait(handle: u32, budget: u64, result: *i32) callconv(.c) i32 {
        std.debug.assert(!state.stream_lock and !state.work_reap_gate);
        waits += 1;
        ticks += if (finish_on_wait) @min(budget, 3) else budget;
        if (finish_on_wait) slots[handle].state = a.driver_work_state_completed;
        result.* = slots[handle].result;
        return if (slots[handle].state == a.driver_work_state_completed) 0 else 1; // native Work wait timeout
    }
    fn register(_: [*:0]const u8, descriptor: *const anyopaque) callconv(.c) i32 {
        const value: *const r4os.r4dev.AudioOutputIdleBackend = @ptrCast(@alignCast(descriptor));
        return if (value.base.base.version == a.audio_backend_idle_version and value.base.base.size == 104 and value.idle != null) 0 else -1;
    }
    fn registerEpoch(_: [*:0]const u8, callback: a.AudioOutputEpochFn) callconv(.c) i32 {
        var epoch: a.AudioOutputEpoch = .{};
        if (callback(0, &epoch) != 1) return -1;
        return if (epoch.generation == 1 and epoch.count == 1 and epoch.active_index == 0) 0 else -1;
    }
    fn turn(handle: u32) i32 {
        slots[handle].state = a.driver_work_state_running;
        const result = idleCloseWork(@intFromPtr(&state));
        slots[handle].state = if (result == a.driver_work_result_wait) a.driver_work_state_queued else a.driver_work_state_completed;
        slots[handle].result = result;
        return result;
    }
};

test "AC97 idle actual v4 descriptor preserves legacy named output and physical Stop" {
    const t = @import("std").testing;
    IdleCallbackProbe.reset();
    const ctx = context();
    try t.expect(registerPlaybackBackend(&ctx));
    try t.expectEqual(r4os.abi.audio_backend_idle_version, state.backend.base.base.version);
    try t.expectEqual(@as(u32, 104), state.backend.base.base.size);
    try t.expect(state.backend.base.base.stop.? == &stopPlaybackBackend);
    try t.expect(state.backend.idle.? == &idlePlaybackBackend);
    var output: r4os.abi.AudioOutputInfo = .{};
    try t.expectEqual(@as(i32, 1), queryOutput(0, 0, &output));
    try t.expectEqualStrings("AC97", @import("std").mem.sliceTo(&output.id, 0));
    try t.expectEqualStrings("AC97", @import("std").mem.sliceTo(&output.name, 0));
    try t.expectEqual(@as(u32, 48000), output.preferred_rate);
    try t.expectEqual(@as(i32, 0), selectOutput(0, 0));
    try t.expectEqual(@as(i32, -1), selectOutput(0, 1));
    try t.expectEqual(@as(i32, 0), queryOutput(0, 1, &output));
    try t.expectEqual(@as(usize, 0), IdleCallbackProbe.waits);
}

test "AC97 idle actual callback waits for DCH submitters status release and its own ticket" {
    const t = @import("std").testing;
    const a = r4os.abi;
    const p = IdleCallbackProbe;
    p.reset();
    try t.expect(state.queue.commit(1));
    state.work_handles = .{ 1, 2 };
    state.work_pending = true;
    p.slots[1] = .{ .handle = 1, .state = a.driver_work_state_running };
    p.slots[2] = .{ .handle = 2, .state = a.driver_work_state_queued };
    try t.expectEqual(a.service_api_result_busy, idlePlaybackBackend(null));
    const handle = state.idle_close_handle;
    const deadline = state.idle_close.deadline;
    try t.expectEqual(a.driver_work_result_wait, p.turn(handle));
    try t.expectEqual(a.service_api_result_busy, idlePlaybackBackend(null));
    try t.expectEqual(deadline, state.idle_close.deadline);
    try t.expectEqual(@as(usize, 1), state.queue.pending);
    state.status_submitters = 1;
    p.sr = SR_CELV | SR_DCH;
    try t.expectEqual(a.driver_work_result_wait, p.turn(handle));
    try t.expectEqual(@as(usize, 0), p.release_count);
    try t.expect(state.status_stopped and !state.playback_started);
    scheduleStatusWork(&state);
    try t.expectEqual(@as(usize, 1), p.submits);
    try t.expectEqual(@as(u32, 1), state.status_submitters);
    state.status_submitters = 0;
    try t.expectEqual(a.driver_work_result_wait, p.turn(handle));
    p.slots[1].state = a.driver_work_state_completed;
    try t.expectEqual(a.driver_work_result_wait, p.turn(handle));
    try t.expectEqual(a.driver_work_state_cancelled, p.slots[2].state);
    try t.expectEqual(@as(i32, 0), p.turn(handle));
    try t.expect(!state.work_pending);
    try t.expectEqualSlices(u32, &.{ 1, 2 }, p.released[0..p.release_count]);
    try t.expectEqual(@as(i32, 0), idlePlaybackBackend(null));
    try t.expectEqualSlices(u32, &.{ 1, 2, handle }, p.released[0..p.release_count]);
    try t.expectEqual(@as(usize, 1), p.submits);
    try t.expectEqual(a.driver_work_flag_continuation, p.last_flags);
    try t.expectEqual(@as(u64, 0), state.dropped_buffer_count);
    try t.expectEqual(@as(usize, 0), p.waits);
    try t.expect(!state.stream_lock and !state.work_reap_gate);
}

test "AC97 idle only accepted real PCM cancels old intention and cannot reuse its ACK" {
    const t = @import("std").testing;
    const a = r4os.abi;
    const p = IdleCallbackProbe;
    p.reset();
    p.buffers();
    try t.expect(state.queue.commit(1));
    try t.expectEqual(a.service_api_result_busy, idlePlaybackBackend(null));
    const old = state.idle_close_handle;
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    try t.expectEqual(a.service_api_result_invalid, writePcm(null, &bytes, 4, 1, 2, 1));
    try t.expectEqual(@as(u64, 1), state.output_epoch);
    try t.expectEqual(.pending, state.idle_close_result);
    state.stream_lock = true;
    try t.expectEqual(a.service_api_result_busy, writePcm(null, &bytes, 4, 48000, 2, 1));
    state.stream_lock = false;
    try t.expectEqual(@as(u64, 1), state.output_epoch);
    try t.expectEqual(@as(i32, 0), writePcm(null, &bytes, 4, 48000, 2, 1));
    try t.expectEqual(@as(u64, 2), state.output_epoch);
    try t.expectEqual(.none, state.idle_close_result);
    try t.expectEqual(@as(i32, 0), p.turn(old));
    try t.expectEqual(a.service_api_result_busy, idlePlaybackBackend(null));
    try t.expect(state.idle_close_handle != old and state.idle_close_handle != 0);
    try t.expectEqual(@as(usize, 2), p.submits);
    try t.expectEqual(@as(usize, 0), p.waits);
}

test "AC97 idle autonomous deadline or reset failure remains error with DMA retained" {
    const t = @import("std").testing;
    const a = r4os.abi;
    const p = IdleCallbackProbe;
    for ([_]bool{ false, true }) |reset_failure| {
        p.reset();
        p.buffers();
        const dma_address = state.dma[0].virt_addr;
        try t.expect(state.queue.commit(1));
        try t.expectEqual(a.service_api_result_busy, idlePlaybackBackend(null));
        const handle = state.idle_close_handle;
        if (reset_failure) {
            p.sr = SR_CELV | SR_DCH;
            p.fail_reset = true;
        } else p.ticks = state.idle_close.deadline + 1;
        try t.expectEqual(@as(i32, -1), p.turn(handle));
        try t.expectEqual(@as(i32, -1), state.last_result);
        try t.expectEqual(.failed, state.idle_close_result);
        try t.expect(state.present and state.backend_registered);
        try t.expectEqual(dma_address, state.dma[0].virt_addr);
        try t.expectEqual(@as(i32, -1), idlePlaybackBackend(null));
        try t.expectEqual(@as(u32, 0), state.idle_close_handle);
        try t.expectEqual(@as(usize, 0), p.waits);
    }
}

test "AC97 idle refused release stays pending until the real retirement budget fails" {
    const t = @import("std").testing;
    const a = r4os.abi;
    const p = IdleCallbackProbe;
    p.reset();
    try t.expect(state.queue.commit(1));
    state.work_handles[0] = 1;
    p.slots[1] = .{ .handle = 1, .state = a.driver_work_state_completed };
    try t.expectEqual(a.service_api_result_busy, idlePlaybackBackend(null));
    const handle = state.idle_close_handle;
    p.sr = SR_CELV | SR_DCH;
    p.fail_release = true;
    try t.expectEqual(a.driver_work_result_wait, p.turn(handle));
    try t.expectEqual(@as(u32, 1), state.work_handles[0]);
    p.ticks = state.idle_close.deadline + 1;
    try t.expectEqual(@as(i32, -1), p.turn(handle));
    try t.expectEqual(a.service_api_result_busy, idlePlaybackBackend(null));
    try t.expectEqual(handle, state.idle_close_handle);
    p.fail_release = false;
    try t.expectEqual(@as(i32, -1), idlePlaybackBackend(null));
    try t.expectEqual(@as(u32, 1), state.work_handles[0]);
    try t.expectEqual(@as(usize, 0), p.waits);
}

test "AC97 idle physical Work join releases both owners and retains timed out resources" {
    const t = @import("std").testing;
    const a = r4os.abi;
    const p = IdleCallbackProbe;
    p.reset();
    state.work_handles[0] = 1;
    state.idle_close_handle = 7;
    p.slots[1] = .{ .handle = 1, .state = a.driver_work_state_running };
    p.slots[7] = .{ .handle = 7, .state = a.driver_work_state_running };
    p.finish_on_wait = true;
    const ctx = context();
    try t.expect(releaseDriverWork(&ctx));
    try t.expectEqualSlices(u32, &.{ 1, 7 }, p.released[0..p.release_count]);
    try t.expectEqual(@as(usize, 2), p.waits);
    try t.expectEqual(@as(u32, 0), state.idle_close_handle);
    p.reset();
    state.work_handles[0] = 1;
    p.slots[1] = .{ .handle = 1, .state = a.driver_work_state_running };
    const stalled = context();
    try t.expect(!releaseDriverWork(&stalled));
    try t.expectEqual(@as(u32, 1), state.work_handles[0]);
    try t.expectEqual(@as(usize, 0), p.release_count);
    try t.expectEqual(@as(u64, 200), p.ticks);
    try t.expect(!state.stream_lock and !state.work_reap_gate);
}

// Host adapter exercises the real registration, teardown and W1C callbacks.
// It is unreachable from the normal module exports.
const InterruptProbe = struct {
    const a = r4os.abi;
    var requested: [32]u8 = undefined;
    var flags: [32]u32 = undefined;
    var requests: usize = 0;
    var removed: [32]u8 = undefined;
    var removals: usize = 0;
    var live: [32]bool = .{false} ** 32;
    var msi: i32 = -1;
    var disable_result: i32 = 0;
    var disables: usize = 0;
    var fail_route: u8 = 0xFF;
    var fail_remove = false;
    var status_submits: usize = 0;
    var foreign_pending = false;
    var foreign_acks: usize = 0;
    var configured: [*:0]const u8 = "23";
    fn reset(line: u8, pin: u8) void {
        IdleCallbackProbe.reset();
        state.info.interrupt_line = line;
        state.info.interrupt_pin = pin;
        const api = &IdleCallbackProbe.api;
        api.pci_enable_msi = enableMsi;
        api.pci_disable_msi = disableMsi;
        api.irq_register = register;
        api.irq_unregister = unregister;
        api.get_option = option;
        api.driver_work_submit = submit;
        api.driver_work_submit_request = submitRequest;
        requests = 0;
        removals = 0;
        live = .{false} ** 32;
        msi = -1;
        disable_result = 0;
        disables = 0;
        fail_route = 0xFF;
        fail_remove = false;
        status_submits = 0;
        foreign_pending = false;
        foreign_acks = 0;
        configured = "23";
    }
    fn option(driver: [*:0]const u8, key: [*:0]const u8) callconv(.c) [*:0]const u8 {
        std.debug.assert(std.mem.eql(u8, std.mem.span(driver), "AC97") and std.mem.eql(u8, std.mem.span(key), "intx-gsi"));
        return configured;
    }
    fn enableMsi(_: u8, _: u8, _: u8, _: u8) callconv(.c) i32 {
        return msi;
    }
    fn disableMsi(_: u8, _: u8, _: u8, _: u8) callconv(.c) i32 {
        disables += 1;
        return disable_result;
    }
    fn register(irq: u8, handler: a.IrqHandler, raw: usize, value: u32) callconv(.c) i32 {
        std.debug.assert(handler == irqHandler and raw == @intFromPtr(&state));
        requested[requests] = irq;
        flags[requests] = value;
        requests += 1;
        if (irq == fail_route) return -1;
        live[irq] = true;
        return 0;
    }
    fn unregister(irq: u8, handler: a.IrqHandler, raw: usize) callconv(.c) i32 {
        std.debug.assert(handler == irqHandler and raw == @intFromPtr(&state) and live[irq]);
        removed[removals] = irq;
        removals += 1;
        if (fail_remove) return -1;
        live[irq] = false;
        return 0;
    }
    fn submit(handler: a.DriverWorkHandler, raw: usize, value: u32, out: *u32) callconv(.c) i32 {
        std.debug.assert(handler == statusWork and raw == @intFromPtr(&state) and value == a.driver_work_flag_from_irq);
        status_submits += 1;
        out.* = 1;
        return 0;
    }
    fn submitRequest(request: *const a.DriverWorkRequest, out: *u32) callconv(.c) i32 {
        std.debug.assert(request.serial_key == @intFromPtr(&state));
        return submit(request.handler, request.context, request.flags, out);
    }
    fn foreignHandler(_: u8, _: usize) callconv(.c) u32 {
        if (!foreign_pending) return 0;
        foreign_pending = false;
        foreign_acks += 1;
        return a.irq_result_handled;
    }
};

test "AC97 IRQ registers only the configured GSI with valid PCI pin and shared level flags" {
    const t = std.testing;
    const p = InterruptProbe;
    p.reset(11, 1);
    const ctx = context();
    try t.expect(setupInterrupts(&ctx));
    try t.expectEqual(@as(usize, 1), p.requests);
    try t.expectEqual(@as(u8, 23), p.requested[0]);
    try t.expectEqual(r4os.abi.irq_flag_shared | r4os.abi.irq_flag_level_low, p.flags[0]);
    try t.expectEqual(@as(usize, 1), state.irq_route_count);
    try t.expectEqual(@as(u8, 1), state.irq_mode);
    try t.expectEqual(CR_IRQ_ENABLE, IdleCallbackProbe.cr & (CR_IRQ_ENABLE | CR_RUN));
}

test "AC97 IRQ missing or malformed GSI and missing pin never admit raw Line or neighbors" {
    const t = std.testing;
    const p = InterruptProbe;
    for ([_][*:0]const u8{ "", "32", "99", "256", "023", "-1", "+1", "1x", " 1", "1 ", "auto" }) |value| {
        p.reset(11, 1);
        p.configured = value;
        const ctx = context();
        try t.expect(!setupInterrupts(&ctx));
        try t.expectEqual(@as(usize, 0), p.requests);
        try t.expectEqual(@as(usize, 0), state.irq_route_count);
        try t.expect(!state.irq_registered);
        try t.expectEqual(@as(u8, 0), IdleCallbackProbe.cr & CR_IRQ_ENABLE);
    }
    for ([_]u8{ 0, 5, 0xFF }) |pin| {
        p.reset(11, pin);
        const ctx = context();
        try t.expect(!setupInterrupts(&ctx));
        try t.expectEqual(@as(usize, 0), p.requests);
    }
    // A board GSI does not depend on a legacy PIC Line being assigned.
    p.reset(0xFF, 4);
    p.configured = "31";
    const ctx = context();
    try t.expect(setupInterrupts(&ctx));
    try t.expectEqualSlices(u8, &.{31}, p.requested[0..p.requests]);
}

test "AC97 IRQ failed exact registration cannot succeed through unrelated GSIs" {
    const t = std.testing;
    const p = InterruptProbe;
    p.reset(19, 4);
    p.configured = "19";
    p.fail_route = 19;
    const ctx = context();
    try t.expect(!setupInterrupts(&ctx));
    try t.expectEqualSlices(u8, &.{19}, p.requested[0..p.requests]);
    try t.expect(!state.irq_registered);
    try t.expectEqual(@as(usize, 0), state.irq_route_count);
}

test "AC97 IRQ successful MSI needs no INTx evidence or fallback registration" {
    const t = std.testing;
    const p = InterruptProbe;
    p.reset(0xFF, 0);
    p.msi = 23;
    const ctx = context();
    try t.expect(setupInterrupts(&ctx));
    try t.expectEqualSlices(u8, &.{23}, p.requested[0..p.requests]);
    try t.expectEqual(r4os.abi.irq_flag_msi, p.flags[0]);
    try t.expectEqual(@as(u8, 2), state.irq_mode);
    try t.expectEqual(@as(usize, 0), p.disables);
    try t.expect(unregisterInterrupts(&ctx));
    try t.expectEqualSlices(u8, &.{23}, p.removed[0..p.removals]);
    try t.expectEqual(@as(usize, 1), p.disables);
}

test "AC97 IRQ MSI fallback requires real disable acknowledgement before exact INTx" {
    const t = std.testing;
    const p = InterruptProbe;
    p.reset(11, 2);
    p.msi = 23;
    p.fail_route = 23;
    p.configured = "19";
    const ctx = context();
    try t.expect(setupInterrupts(&ctx));
    try t.expectEqualSlices(u8, &.{ 23, 19 }, p.requested[0..p.requests]);
    try t.expectEqual(@as(usize, 1), p.disables);
    try t.expectEqual(@as(u8, 1), state.irq_mode);
    try t.expectEqual(@as(u8, 19), state.irq_routes[0]);
    p.reset(11, 2);
    p.msi = 23;
    p.fail_route = 23;
    p.disable_result = -1;
    const blocked = context();
    try t.expect(!setupInterrupts(&blocked));
    try t.expectEqualSlices(u8, &.{23}, p.requested[0..p.requests]);
    try t.expectEqual(@as(u8, 2), state.irq_mode);
    try t.expect(!state.irq_registered);
}

test "AC97 IRQ out of range MSI is disabled and missing INTx still refuses admission" {
    const t = std.testing;
    const p = InterruptProbe;
    p.reset(0xFF, 0);
    p.msi = 32;
    p.configured = "";
    const ctx = context();
    try t.expect(!setupInterrupts(&ctx));
    try t.expectEqual(@as(usize, 1), p.disables);
    try t.expectEqual(@as(usize, 0), p.requests);
}

test "AC97 IRQ failed unregister and MSI disable retain exact retry evidence" {
    const t = std.testing;
    const p = InterruptProbe;
    p.reset(11, 1);
    p.msi = 23;
    const ctx = context();
    try t.expect(setupInterrupts(&ctx));
    p.fail_remove = true;
    try t.expect(!unregisterInterrupts(&ctx));
    try t.expect(state.irq_registered and p.live[23]);
    try t.expectEqual(@as(usize, 1), state.irq_route_count);
    try t.expectEqual(@as(usize, 0), p.disables);
    p.fail_remove = false;
    p.disable_result = -1;
    try t.expect(!unregisterInterrupts(&ctx));
    try t.expect(!state.irq_registered and !p.live[23]);
    try t.expectEqual(@as(usize, 0), state.irq_route_count);
    try t.expectEqual(@as(u8, 2), state.irq_mode);
    p.disable_result = 0;
    try t.expect(unregisterInterrupts(&ctx));
    try t.expectEqualSlices(u8, &.{ 23, 23 }, p.removed[0..p.removals]);
    try t.expectEqual(@as(u8, 0), state.irq_mode);
}

test "AC97 IRQ actual shared callbacks acknowledge only their own W1C status" {
    const t = std.testing;
    const p = InterruptProbe;
    p.reset(11, 1);
    const ctx = context();
    try t.expect(setupInterrupts(&ctx));
    p.foreign_pending = true;
    IdleCallbackProbe.sr = SR_DCH | SR_CELV;
    try t.expectEqual(@as(u32, 0), irqHandler(23, @intFromPtr(&state)));
    try t.expectEqual(r4os.abi.irq_result_handled, p.foreignHandler(23, 0));
    try t.expectEqual(@as(usize, 1), p.foreign_acks);
    try t.expectEqual(@as(usize, 0), p.status_submits);
    try t.expectEqual(@as(u64, 1), state.irq_unhandled);
    IdleCallbackProbe.sr |= SR_LVBCI | SR_BCIS;
    try t.expectEqual(r4os.abi.irq_result_handled, irqHandler(23, @intFromPtr(&state)));
    try t.expectEqual(@as(u16, SR_DCH | SR_CELV), IdleCallbackProbe.sr);
    try t.expectEqual(@as(u16, SR_LVBCI | SR_BCIS), state.irq_pending_status);
    try t.expectEqual(@as(u8, 23), state.irq_active_route);
    try t.expectEqual(@as(usize, 1), p.status_submits);
    try t.expectEqual(@as(u64, 1), state.irq_count);
    try t.expectEqual(@as(u32, 0), irqHandler(23, @intFromPtr(&state)));
    try t.expectEqual(@as(usize, 1), p.status_submits);
    try t.expectEqual(@as(u32, 0), p.foreignHandler(23, 0));
}

fn setLastResult(result: i32) i32 {
    state.last_result = result;
    if (result == r4os.abi.service_api_result_busy) {
        state.busy_count += 1;
    } else if (result < 0) {
        state.error_count += 1;
    }
    return result;
}

fn finishWrite(result: i32, start_tick: u64) i32 {
    recordTickStat(&state.write_total_ticks, &state.write_max_ticks, &state.write_last_ticks, start_tick);
    return setLastResult(result);
}

fn recordTickStat(total: *u64, max: *u64, last: *u64, start_tick: u64) void {
    const now = context().tickCount();
    const elapsed = if (now >= start_tick) now - start_tick else 0;
    total.* +%= elapsed;
    last.* = elapsed;
    if (elapsed > max.*) max.* = elapsed;
}

fn context() r4os.r4dev.DriverContext {
    return r4os.r4dev.DriverContext.init(state.api);
}

fn logDevice(ctx: *const r4os.r4dev.DriverContext, info: r4os.abi.PciDeviceInfo) void {
    var line: [96:0]u8 = undefined;
    var len: usize = 0;
    appendText(&line, &len, "AC97.R4D device ");
    appendDec(&line, &len, info.bus);
    appendText(&line, &len, ":");
    appendDec(&line, &len, info.device);
    appendText(&line, &len, ".");
    appendDec(&line, &len, info.function);
    appendText(&line, &len, " vendor=0x");
    appendHex(&line, &len, info.vendor_id, 4);
    appendText(&line, &len, " device=0x");
    appendHex(&line, &len, info.device_id, 4);
    appendText(&line, &len, " line=");
    appendDec(&line, &len, info.interrupt_line);
    appendText(&line, &len, " pin=");
    appendDec(&line, &len, info.interrupt_pin);
    logLine(ctx, &line, len);
}

fn logIoPorts(ctx: *const r4os.r4dev.DriverContext) void {
    var line: [80:0]u8 = undefined;
    var len: usize = 0;
    appendText(&line, &len, "AC97.R4D io nam=0x");
    appendHex(&line, &len, state.nam_port, 4);
    appendText(&line, &len, " nabm=0x");
    appendHex(&line, &len, state.nabm_port, 4);
    logLine(ctx, &line, len);
}

fn logDma(ctx: *const r4os.r4dev.DriverContext) void {
    var line: [96:0]u8 = undefined;
    var len: usize = 0;
    appendText(&line, &len, "AC97.R4D dma bdl=0x");
    appendHex(&line, &len, state.bdl.phys_addr, 8);
    appendText(&line, &len, " buffers=");
    appendDec(&line, &len, DMA_BUFFER_COUNT);
    appendText(&line, &len, " bytes=");
    appendDec(&line, &len, MAX_DMA_BYTES);
    logLine(ctx, &line, len);
}

fn logLine(ctx: *const r4os.r4dev.DriverContext, line: anytype, len: usize) void {
    var capped = len;
    if (capped >= line.len) capped = line.len - 1;
    line[capped] = 0;
    const text: [*:0]u8 = @ptrCast(line);
    ctx.logInfo(text);
}

fn appendText(buf: anytype, len: *usize, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len and len.* + 1 < buf.len) : (i += 1) {
        buf[len.*] = text[i];
        len.* += 1;
    }
}

fn appendDec(buf: anytype, len: *usize, value: anytype) void {
    var n: u64 = @intCast(value);
    var tmp: [20]u8 = undefined;
    var count: usize = 0;
    if (n == 0) {
        appendText(buf, len, "0");
        return;
    }
    while (n > 0 and count < tmp.len) : (count += 1) {
        tmp[count] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    while (count > 0) {
        count -= 1;
        if (len.* + 1 >= buf.len) return;
        buf[len.*] = tmp[count];
        len.* += 1;
    }
}

fn appendHex(buf: anytype, len: *usize, value: anytype, digits: usize) void {
    const hex = "0123456789ABCDEF";
    const raw: u64 = @intCast(value);
    var shift: usize = digits * 4;
    while (shift > 0) {
        shift -= 4;
        const nibble: usize = @intCast((raw >> @intCast(shift)) & 0xF);
        if (len.* + 1 >= buf.len) return;
        buf[len.*] = hex[nibble];
        len.* += 1;
    }
}
