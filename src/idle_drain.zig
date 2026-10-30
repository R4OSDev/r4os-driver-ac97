//! One owned AC97 drain/retirement turn. The caller starts the absolute
//! budget before submitting resident Work; polling never restarts it.
const std = @import("std");

pub const Identity = struct { output: u64, reset: u64, pci: u32 };
pub const Result = enum { pending, complete, changed, drain_timeout, retirement_timeout, failed };
pub const Retirement = enum { pending, complete, failed };
pub const State = struct {
    phase: enum { idle, draining, retiring, terminal } = .idle,
    identity: Identity = .{ .output = 0, .reset = 0, .pci = 0 },
    deadline: u64 = 0,
    result: Result = .pending,

    pub fn reset(self: *State) void {
        self.* = .{};
    }
    pub fn start(self: *State, identity: Identity, now: u64, drain_ticks: u64) void {
        self.* = .{ .phase = .draining, .identity = identity, .deadline = now +| drain_ticks };
    }
    fn finish(self: *State, result: Result) Result {
        self.phase = .terminal;
        self.result = result;
        return result;
    }
    pub fn poll(self: *State, owner: anytype, retirement_ticks: u64) Result {
        if (self.phase == .terminal) return self.result;
        if (self.phase == .idle) return self.finish(.failed);
        if (!std.meta.eql(self.identity, owner.identity())) return self.finish(.changed);
        if (self.phase == .draining) {
            if (owner.now() > self.deadline) return self.finish(.drain_timeout);
            const drained = owner.pump();
            if (!std.meta.eql(self.identity, owner.identity())) return self.finish(.changed);
            if (owner.now() > self.deadline) return self.finish(.drain_timeout);
            if (!drained) return .pending;
            if (!owner.quiet()) return self.finish(.failed);
            // Only this confirmed drained reset may adopt its new epoch.
            self.identity = owner.identity();
            self.phase = .retiring;
            self.deadline = owner.now() +| retirement_ticks;
        }
        if (owner.now() > self.deadline) return self.finish(.retirement_timeout);
        const result = owner.retire();
        if (!std.meta.eql(self.identity, owner.identity())) return self.finish(.changed);
        if (owner.now() > self.deadline) return self.finish(.retirement_timeout);
        return switch (result) {
            .pending => .pending,
            .failed => self.finish(.failed),
            .complete => self.finish(.complete),
        };
    }
};

const Fixture = struct {
    tick: u64 = 10,
    epoch: Identity = .{ .output = 1, .reset = 2, .pci = 0x18 },
    pending: usize = 1,
    halted: bool = false,
    handles: usize = 2,
    pumps: usize = 0,
    quiets: usize = 0,
    retires: usize = 0,
    quiet_ok: bool = true,
    retire_ok: bool = true,
    change_during_pump: bool = false,
    change_during_retire: bool = false,
    pub fn identity(self: *@This()) Identity {
        return self.epoch;
    }
    pub fn now(self: *@This()) u64 {
        return self.tick;
    }
    pub fn pump(self: *@This()) bool {
        self.pumps += 1;
        if (self.change_during_pump) self.epoch.output += 1;
        return self.pending == 0 and self.halted;
    }
    pub fn quiet(self: *@This()) bool {
        std.debug.assert(self.pending == 0 and self.halted);
        self.quiets += 1;
        if (self.quiet_ok) self.epoch.reset += 1;
        return self.quiet_ok;
    }
    pub fn retire(self: *@This()) Retirement {
        self.retires += 1;
        if (self.change_during_retire) self.epoch.reset += 1;
        if (!self.retire_ok) return .failed;
        return if (self.handles == 0) .complete else .pending;
    }
};

test "one turn preserves queued PCM DCH and actual Work release before success" {
    var owner: Fixture = .{};
    var state: State = .{};
    state.start(owner.identity(), owner.now(), 2000);
    try std.testing.expectEqual(Result.pending, state.poll(&owner, 100));
    try std.testing.expectEqual(@as(usize, 1), owner.pumps);
    try std.testing.expectEqual(@as(usize, 0), owner.quiets);
    owner.pending = 0;
    try std.testing.expectEqual(Result.pending, state.poll(&owner, 100));
    try std.testing.expectEqual(@as(usize, 0), owner.quiets);
    owner.halted = true;
    try std.testing.expectEqual(Result.pending, state.poll(&owner, 100));
    try std.testing.expectEqual(@as(usize, 1), owner.quiets);
    try std.testing.expectEqual(@as(u64, 3), state.identity.reset);
    owner.handles = 0;
    try std.testing.expectEqual(Result.complete, state.poll(&owner, 100));
    try std.testing.expectEqual(Result.complete, state.poll(&owner, 100));
    try std.testing.expectEqual(@as(usize, 2), owner.retires);
    try std.testing.expectEqual(@as(usize, 1), owner.quiets);
}

test "original 2000 tick drain includes queue delay and never refreshes on poll" {
    var owner: Fixture = .{};
    var state: State = .{};
    state.start(owner.identity(), owner.now(), 2000);
    const deadline = state.deadline;
    owner.tick = deadline;
    try std.testing.expectEqual(Result.pending, state.poll(&owner, 100));
    try std.testing.expectEqual(deadline, state.deadline);
    owner.tick += 1;
    try std.testing.expectEqual(Result.drain_timeout, state.poll(&owner, 100));
    try std.testing.expectEqual(@as(usize, 1), owner.pumps);
    try std.testing.expectEqual(@as(usize, 0), owner.quiets);
    state.start(owner.identity(), 10, 2000);
    try std.testing.expectEqual(Result.drain_timeout, state.poll(&owner, 100));
    try std.testing.expectEqual(@as(usize, 1), owner.pumps);
}

test "exact output reset and PCI change cannot acknowledge old PCM" {
    for (0..3) |field| {
        var owner: Fixture = .{ .pending = 0, .halted = true, .handles = 0 };
        var state: State = .{};
        state.start(owner.identity(), owner.now(), 2000);
        switch (field) {
            0 => owner.epoch.output += 1,
            1 => owner.epoch.reset += 1,
            else => owner.epoch.pci += 1,
        }
        try std.testing.expectEqual(Result.changed, state.poll(&owner, 100));
        try std.testing.expectEqual(@as(usize, 0), owner.pumps);
        try std.testing.expectEqual(@as(usize, 0), owner.quiets);
    }
    var owner: Fixture = .{ .pending = 0, .halted = true, .change_during_pump = true };
    var state: State = .{};
    state.start(owner.identity(), owner.now(), 2000);
    try std.testing.expectEqual(Result.changed, state.poll(&owner, 100));
    try std.testing.expectEqual(@as(usize, 0), owner.quiets);
}

test "retirement keeps original deadline and rejects foreign reset" {
    var owner: Fixture = .{ .pending = 0, .halted = true };
    var state: State = .{};
    state.start(owner.identity(), owner.now(), 2000);
    try std.testing.expectEqual(Result.pending, state.poll(&owner, 100));
    const deadline = state.deadline;
    owner.tick = deadline;
    try std.testing.expectEqual(Result.pending, state.poll(&owner, 100));
    try std.testing.expectEqual(deadline, state.deadline);
    owner.tick += 1;
    owner.handles = 0;
    try std.testing.expectEqual(Result.retirement_timeout, state.poll(&owner, 100));
    try std.testing.expectEqual(@as(usize, 1), owner.quiets);
    owner = .{ .pending = 0, .halted = true, .change_during_retire = true };
    state.start(owner.identity(), owner.now(), 2000);
    try std.testing.expectEqual(Result.changed, state.poll(&owner, 100));
}

test "failed reset and actual release failure cannot become successful Close" {
    var owner: Fixture = .{ .pending = 0, .halted = true, .quiet_ok = false };
    var state: State = .{};
    state.start(owner.identity(), owner.now(), 2000);
    try std.testing.expectEqual(Result.failed, state.poll(&owner, 100));
    try std.testing.expectEqual(@as(usize, 0), owner.retires);
    try std.testing.expectEqual(@as(usize, 2), owner.handles);
    owner = .{ .pending = 0, .halted = true, .retire_ok = false };
    state.start(owner.identity(), owner.now(), 2000);
    try std.testing.expectEqual(Result.failed, state.poll(&owner, 100));
    try std.testing.expectEqual(@as(usize, 2), owner.handles);
}

test "cancellation is explicit and idle poll cannot invent a fresh budget" {
    var owner: Fixture = .{};
    var state: State = .{};
    state.start(owner.identity(), owner.now(), 2000);
    state.reset();
    try std.testing.expectEqual(Result.failed, state.poll(&owner, 100));
    try std.testing.expectEqual(@as(usize, 0), owner.pumps);
    state.start(owner.identity(), std.math.maxInt(u64) - 1, 2000);
    try std.testing.expectEqual(std.math.maxInt(u64), state.deadline);
}
