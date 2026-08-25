const std = @import("std");

pub const Finish = enum {
    stop,
    resubmit,
};

/// Completes exactly one bounded status pass. If an IRQ changed the observed
/// generation while the pass ran, the caller submits a fresh deadline job.
pub fn finishPass(pending: *bool, generation: *u64, observed_generation: u64, shutting_down: *bool) Finish {
    @atomicStore(bool, pending, false, .release);
    if (@atomicLoad(bool, shutting_down, .acquire)) return .stop;
    return if (@atomicLoad(u64, generation, .acquire) == observed_generation) .stop else .resubmit;
}

test "changed IRQ generation requests a bounded successor" {
    var pending = true;
    var generation: u64 = 3;
    var shutting_down = false;

    try std.testing.expectEqual(Finish.stop, finishPass(&pending, &generation, 3, &shutting_down));
    try std.testing.expect(!pending);

    pending = true;
    generation = 4;
    try std.testing.expectEqual(Finish.resubmit, finishPass(&pending, &generation, 3, &shutting_down));
    try std.testing.expect(!pending);

    pending = true;
    shutting_down = true;
    try std.testing.expectEqual(Finish.stop, finishPass(&pending, &generation, 3, &shutting_down));
    try std.testing.expect(!pending);
}
