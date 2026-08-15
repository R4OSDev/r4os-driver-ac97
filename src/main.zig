const r4os = @import("r4os");
const pcm = r4os.audio_pcm;

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
const SR_CLEAR: u16 = 0x001C;
const SR_DCH: u16 = 0x0001;
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
    backend: r4os.abi.AudioBackend = .{},
    backend_registered: bool = false,
    present: bool = false,
    playback_started: bool = false,
    next_dma_index: usize = 0,
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
    timeout_count: u64 = 0,
    dch_count: u64 = 0,
    underrun_count: u64 = 0,
    fifo_error_count: u64 = 0,
    status_irq_count: u64 = 0,
    error_count: u64 = 0,
    converted_frame_count: u64 = 0,
    last_result: i32 = 0,
    last_status: u16 = 0,
    previous_status: u16 = 0,
    last_source_rate: u32 = 0,
    last_source_channels: u16 = 0,
    last_source_format: u16 = 0,
    last_output_frames: usize = 0,
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
        shutdownHardware(&ctx);
        return -5;
    }

    codecReset(&ctx);
    resetPlayback(&ctx);
    state.present = true;
    if (!registerPlaybackBackend(&ctx)) {
        ctx.logError("AC97.R4D audio backend register failed");
        shutdownHardware(&ctx);
        return -6;
    }
    state.initialized = true;
    ctx.logInfo("AC97.R4D playback backend ready");
    return 0;
}

export fn ac97_shutdown() callconv(.c) i32 {
    var ctx = context();
    ctx.logInfo("AC97.R4D shutdown");
    unregisterPlaybackBackend(&ctx);
    shutdownHardware(&ctx);
    return 0;
}

fn findDevice(ctx: *const r4os.r4dev.DriverContext) ?r4os.abi.PciDeviceInfo {
    var info: r4os.abi.PciDeviceInfo = .{};
    const found = ctx.pciFindByClass(CLASS_MULTIMEDIA, SUBCLASS_AUDIO, 0, &info);
    if (found < 0) return null;
    return info;
}

fn allocDmaState(ctx: *const r4os.r4dev.DriverContext) bool {
    if (ctx.allocDmaRegion(@intCast(@sizeOf(BdlEntry) * BDL_ENTRY_COUNT), 16, &state.bdl) != 0) return false;
    if (state.bdl.phys_addr == 0 or state.bdl.virt_addr == 0) return false;

    var i: usize = 0;
    while (i < DMA_BUFFER_COUNT) : (i += 1) {
        if (ctx.allocDmaRegion(MAX_DMA_BYTES, 16, &state.dma[i]) != 0) return false;
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
        .formats = r4os.abi.audio_backend_format_s16le | r4os.abi.audio_backend_format_u8,
        .min_rate = MIN_RATE,
        .max_rate = MAX_RATE,
        .preferred_rate = pcm.TARGET_RATE,
        .max_channels = pcm.TARGET_CHANNELS,
        .write_pcm = writePcm,
        .stop = stopPlaybackBackend,
        .shutdown = shutdownBackend,
        .status = backendStatus,
    };
    const rc = ctx.registerAudioOutputBackend("AC97", &state.backend);
    state.last_result = rc;
    if (rc != 0) {
        state.error_count += 1;
        return false;
    }
    state.backend_registered = true;
    return true;
}

fn unregisterPlaybackBackend(ctx: *const r4os.r4dev.DriverContext) void {
    if (!state.backend_registered) return;
    _ = ctx.unregisterAudioBackend("AC97");
    state.backend_registered = false;
}

fn writePcm(context_arg: ?*anyopaque, data: [*]const u8, len: u32, rate: u32, channels: u16, format: u16) callconv(.c) i32 {
    _ = context_arg;
    var ctx = context();
    const write_start = ctx.tickCount();
    if (!state.present or state.nabm_port == 0) return finishWrite(-1, write_start);
    const input = data[0..@as(usize, @intCast(len))];
    if (pcm.outputFrameCount(input.len, rate, channels, format) == 0) return finishWrite(-2, write_start);

    serviceStatus(&ctx);
    state.last_source_rate = rate;
    state.last_source_channels = channels;
    state.last_source_format = format;
    state.last_output_frames = 0;
    state.resampler_state.beginChunk(rate, channels, format);

    var wrote_any = false;
    while (true) {
        const index = state.next_dma_index;
        if (state.playback_started and !waitBufferReusable(&ctx, index)) {
            state.timeout_count += 1;
            resetPlayback(&ctx);
        }

        const out = dmaSlice(index) orelse return finishWrite(-3, write_start);
        const converted = pcm.convertStreamingToStereoS16(&state.resampler_state, input, rate, channels, format, out);
        if (converted < pcm.TARGET_FRAME_BYTES) break;
        queueDmaBuffer(&ctx, index, converted);
        const frames = converted / pcm.TARGET_FRAME_BYTES;
        state.last_output_frames += frames;
        state.converted_frame_count += frames;
        wrote_any = true;
    }

    return finishWrite(if (wrote_any) 0 else -4, write_start);
}

fn stopPlaybackBackend(context_arg: ?*anyopaque) callconv(.c) i32 {
    _ = context_arg;
    var ctx = context();
    stopPlayback(&ctx);
    state.last_result = 0;
    return 0;
}

fn shutdownBackend(context_arg: ?*anyopaque) callconv(.c) i32 {
    _ = context_arg;
    var ctx = context();
    shutdownHardware(&ctx);
    state.last_result = 0;
    return 0;
}

fn backendStatus(context_arg: ?*anyopaque, out: *r4os.abi.AudioBackendStatus) callconv(.c) i32 {
    _ = context_arg;
    out.* = .{
        .active = if (state.present and state.backend_registered) 1 else 0,
        .writes = state.write_count,
        .underruns = state.underrun_count + state.dch_count,
        .errors = state.error_count + state.timeout_count + state.fifo_error_count,
        .last_result = state.last_result,
        .reserved = 0,
        .refills = state.refill_count,
        .silence_refills = 0,
        .buffer_bytes = @as(u64, @intCast(DMA_BUFFER_COUNT)) * @as(u64, MAX_DMA_BYTES),
        .queued_buffers = @intCast(DMA_BUFFER_COUNT),
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

fn queueDmaBuffer(ctx: *const r4os.r4dev.DriverContext, index: usize, len: usize) void {
    const refill_start = ctx.tickCount();
    serviceStatus(ctx);
    const starting = !state.playback_started;
    state.write_count += 1;
    state.refill_count += 1;
    const bdl: [*]volatile BdlEntry = @ptrFromInt(state.bdl.virt_addr);
    bdl[index] = .{
        .addr = @truncate(state.dma[index].phys_addr),
        .samples = @intCast(len / 2),
        .control = BDL_IOC,
    };
    if (starting) {
        resetPlayback(ctx);
        ctx.portOutl(state.nabm_port + PO_BDBAR, @truncate(state.bdl.phys_addr));
        state.playback_started = true;
    }
    ctx.portOutb(state.nabm_port + PO_LVI, @intCast(index));
    ctx.portOutb(state.nabm_port + PO_CR, ctx.portInb(state.nabm_port + PO_CR) | CR_RUN);
    state.next_dma_index = (index + 1) % DMA_BUFFER_COUNT;
    recordTickStat(&state.refill_total_ticks, &state.refill_max_ticks, &state.refill_last_ticks, refill_start);
}

fn resetPlayback(ctx: *const r4os.r4dev.DriverContext) void {
    if (state.nabm_port == 0) return;
    state.reset_count += 1;
    ctx.portOutb(state.nabm_port + PO_CR, CR_RESET);
    var guard: u32 = 0;
    while ((ctx.portInb(state.nabm_port + PO_CR) & CR_RESET) != 0 and guard < 100000) : (guard += 1) {}
    ctx.portOutw(state.nabm_port + PO_SR, SR_CLEAR);
    state.previous_status = 0;
    state.last_status = ctx.portInw(state.nabm_port + PO_SR);
    state.playback_started = false;
    state.next_dma_index = 0;
    state.resampler_state.reset();
    if (state.bdl.phys_addr != 0) ctx.portOutl(state.nabm_port + PO_BDBAR, @truncate(state.bdl.phys_addr));
}

fn stopPlayback(ctx: *const r4os.r4dev.DriverContext) void {
    if (!state.present or state.nabm_port == 0) return;
    serviceStatus(ctx);
    drainPlayback(ctx);
    ctx.portOutb(state.nabm_port + PO_CR, ctx.portInb(state.nabm_port + PO_CR) & ~CR_RUN);
    ctx.portOutb(state.nabm_port + PO_CR, CR_RESET);
    var guard: u32 = 0;
    while ((ctx.portInb(state.nabm_port + PO_CR) & CR_RESET) != 0 and guard < 100000) : (guard += 1) {}
    ctx.portOutw(state.nabm_port + PO_SR, SR_CLEAR);
    state.previous_status = 0;
    state.last_status = ctx.portInw(state.nabm_port + PO_SR);
    clearBdl();
    state.playback_started = false;
    state.next_dma_index = 0;
    state.resampler_state.reset();
    state.stop_count += 1;
}

fn shutdownHardware(ctx: *const r4os.r4dev.DriverContext) void {
    stopPlayback(ctx);
    if (state.nabm_port != 0) {
        ctx.portOutb(state.nabm_port + PO_CR, ctx.portInb(state.nabm_port + PO_CR) & ~CR_RUN);
        ctx.portOutb(state.nabm_port + PO_CR, CR_RESET);
        var guard: u32 = 0;
        while ((ctx.portInb(state.nabm_port + PO_CR) & CR_RESET) != 0 and guard < 100000) : (guard += 1) {}
        ctx.portOutw(state.nabm_port + PO_SR, SR_CLEAR);
    }
    clearBdl();

    var i: usize = 0;
    while (i < DMA_BUFFER_COUNT) : (i += 1) {
        if (state.dma[i].phys_addr != 0) ctx.freeDmaRegion(&state.dma[i]);
    }
    if (state.bdl.phys_addr != 0) ctx.freeDmaRegion(&state.bdl);
    state.initialized = false;
    state.present = false;
    state.playback_started = false;
    state.next_dma_index = 0;
    state.backend_registered = false;
}

fn waitBufferReusable(ctx: *const r4os.r4dev.DriverContext, index: usize) bool {
    const deadline = ctx.tickCount() + msTicks(ctx, PLAYBACK_WAIT_MS);
    while (ctx.tickCount() <= deadline) {
        serviceStatus(ctx);
        if ((ctx.portInb(state.nabm_port + PO_CR) & CR_RUN) == 0) return true;
        if ((ctx.portInb(state.nabm_port + PO_CIV) & 0x1F) != @as(u8, @intCast(index))) return true;
    }
    return false;
}

fn drainPlayback(ctx: *const r4os.r4dev.DriverContext) void {
    if (!state.playback_started) return;
    state.drain_count += 1;
    const deadline = ctx.tickCount() + msTicks(ctx, DRAIN_WAIT_MS);
    while (ctx.tickCount() <= deadline) {
        serviceStatus(ctx);
        const cr = ctx.portInb(state.nabm_port + PO_CR);
        const sr = ctx.portInw(state.nabm_port + PO_SR);
        if ((cr & CR_RUN) == 0 or (sr & SR_DCH) != 0) return;
    }
}

fn serviceStatus(ctx: *const r4os.r4dev.DriverContext) void {
    if (!state.present or state.nabm_port == 0) return;
    const sr = ctx.portInw(state.nabm_port + PO_SR);
    const raised = sr & ~state.previous_status;
    state.last_status = sr;
    if ((raised & SR_BCIS) != 0) state.status_irq_count += 1;
    if ((raised & SR_DCH) != 0) state.dch_count += 1;
    if ((raised & SR_LVBCI) != 0) state.underrun_count += 1;
    if ((raised & SR_FIFOE) != 0) state.fifo_error_count += 1;
    if ((sr & SR_CLEAR) != 0) ctx.portOutw(state.nabm_port + PO_SR, sr & SR_CLEAR);
    state.previous_status = ctx.portInw(state.nabm_port + PO_SR);
}

fn dmaSlice(index: usize) ?[]u8 {
    if (index >= DMA_BUFFER_COUNT) return null;
    const buffer = state.dma[index];
    if (buffer.virt_addr == 0 or buffer.bytes == 0) return null;
    const bytes = if (buffer.bytes < MAX_DMA_BYTES) buffer.bytes else MAX_DMA_BYTES;
    const ptr: [*]u8 = @ptrFromInt(buffer.virt_addr);
    return ptr[0..@as(usize, @intCast(bytes))];
}

fn setLastResult(result: i32) i32 {
    state.last_result = result;
    if (result < 0) state.error_count += 1;
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
