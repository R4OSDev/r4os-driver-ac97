const std = @import("std");

pub const Finish = enum {
    stop,
    resubmit,
};

/// Completes one bounded status pass. A busy owner retains the work just like
/// an IRQ arriving during the pass; the caller submits a fresh deadline job.
pub fn finishPass(pending: *bool, generation: *u64, observed_generation: u64, shutting_down: *bool, completed: bool) Finish {
    @atomicStore(bool, pending, false, .release);
    if (@atomicLoad(bool, shutting_down, .acquire)) return .stop;
    if (!completed) return .resubmit;
    return if (@atomicLoad(u64, generation, .acquire) == observed_generation) .stop else .resubmit;
}

test "changed IRQ generation requests a bounded successor" {
    var pending = true;
    var generation: u64 = 3;
    var shutting_down = false;

    try std.testing.expectEqual(Finish.stop, finishPass(&pending, &generation, 3, &shutting_down, true));
    try std.testing.expect(!pending);

    pending = true;
    try std.testing.expectEqual(Finish.resubmit, finishPass(&pending, &generation, generation, &shutting_down, false));
    try std.testing.expect(!pending);

    pending = true;
    generation = 4;
    try std.testing.expectEqual(Finish.resubmit, finishPass(&pending, &generation, 3, &shutting_down, true));
    try std.testing.expect(!pending);

    pending = true;
    shutting_down = true;
    try std.testing.expectEqual(Finish.stop, finishPass(&pending, &generation, 3, &shutting_down, true));
    try std.testing.expect(!pending);
}
