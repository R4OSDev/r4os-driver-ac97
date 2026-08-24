pub const DescriptorQueue = struct {
    descriptor_count: usize = 0,
    capacity: usize = 0,
    producer: usize = 0,
    consumer: usize = 0,
    pending: usize = 0,

    pub fn init(descriptor_count: usize, capacity: usize) DescriptorQueue {
        if (descriptor_count == 0 or capacity == 0 or capacity >= descriptor_count) return .{};
        return .{ .descriptor_count = descriptor_count, .capacity = capacity };
    }

    pub fn reset(self: *DescriptorQueue) void {
        const descriptor_count = self.descriptor_count;
        const capacity = self.capacity;
        self.* = .{ .descriptor_count = descriptor_count, .capacity = capacity };
    }

    pub fn available(self: *const DescriptorQueue) usize {
        if (self.descriptor_count == 0 or self.pending > self.capacity) return 0;
        return self.capacity - self.pending;
    }

    pub fn descriptorAt(self: *const DescriptorQueue, offset: usize) ?usize {
        if (self.descriptor_count == 0 or offset >= self.available()) return null;
        return (self.producer + offset) % self.descriptor_count;
    }

    pub fn commit(self: *DescriptorQueue, count: usize) bool {
        if (self.descriptor_count == 0 or count == 0 or count > self.available()) return false;
        if (self.pending == 0) self.consumer = self.producer;
        self.producer = (self.producer + count) % self.descriptor_count;
        self.pending += count;
        return true;
    }

    pub fn observe(self: *DescriptorQueue, current: usize, last_valid_completed: bool) usize {
        if (self.descriptor_count == 0 or current >= self.descriptor_count or self.pending == 0) return 0;
        const distance = ringDistance(self.consumer, current, self.descriptor_count);
        if (distance > self.pending) return 0;

        var retired = self.retire(distance);
        if (last_valid_completed and self.pending != 0 and self.consumer == current) {
            retired += self.retire(1);
        }
        return retired;
    }

    fn retire(self: *DescriptorQueue, count: usize) usize {
        const retired = @min(count, self.pending);
        self.consumer = (self.consumer + retired) % self.descriptor_count;
        self.pending -= retired;
        return retired;
    }
};

pub fn plannedOutputFrames(input_frames: usize, rate: u32, target_rate: u32, phase_q16: u64) ?usize {
    if (input_frames == 0 or rate == 0 or target_rate == 0) return null;
    const phase_one: u64 = 65_536;
    const step = (@as(u64, rate) * phase_one) / target_rate;
    if (step == 0) return null;
    const limit = @as(u64, @intCast(input_frames)) * phase_one;
    if (phase_q16 >= limit) return 0;
    return @intCast((limit - phase_q16 + step - 1) / step);
}

fn ringDistance(from: usize, to: usize, count: usize) usize {
    return if (to >= from) to - from else count - from + to;
}

test "queue enforces bounded backpressure before publishing" {
    const std = @import("std");
    var queue = DescriptorQueue.init(32, 8);
    try std.testing.expectEqual(@as(usize, 8), queue.available());
    try std.testing.expectEqual(@as(?usize, 0), queue.descriptorAt(0));
    try std.testing.expectEqual(@as(?usize, 7), queue.descriptorAt(7));
    try std.testing.expectEqual(@as(?usize, null), queue.descriptorAt(8));
    try std.testing.expect(queue.commit(8));
    try std.testing.expectEqual(@as(usize, 0), queue.available());
    try std.testing.expect(!queue.commit(1));
}

test "CIV advancement and last-valid completion retire exact descriptors" {
    const std = @import("std");
    var queue = DescriptorQueue.init(32, 8);
    try std.testing.expect(queue.commit(8));
    try std.testing.expectEqual(@as(usize, 3), queue.observe(3, false));
    try std.testing.expectEqual(@as(usize, 5), queue.pending);
    try std.testing.expectEqual(@as(usize, 5), queue.observe(7, true));
    try std.testing.expectEqual(@as(usize, 0), queue.pending);
    try std.testing.expectEqual(@as(usize, 8), queue.consumer);
}

test "CIV at the producer proves every preceding descriptor complete" {
    const std = @import("std");
    var queue = DescriptorQueue.init(32, 8);
    try std.testing.expect(queue.commit(3));
    try std.testing.expectEqual(@as(usize, 3), queue.observe(3, false));
    try std.testing.expectEqual(@as(usize, 0), queue.pending);
}

test "queue ignores a CIV outside its bounded ownership window" {
    const std = @import("std");
    var queue = DescriptorQueue.init(32, 8);
    try std.testing.expect(queue.commit(2));
    try std.testing.expectEqual(@as(usize, 0), queue.observe(10, false));
    try std.testing.expectEqual(@as(usize, 2), queue.pending);
}

test "descriptor ownership wraps across the complete hardware ring" {
    const std = @import("std");
    var queue = DescriptorQueue.init(32, 8);
    var cycle: usize = 0;
    while (cycle < 4) : (cycle += 1) {
        const last = queue.descriptorAt(7).?;
        try std.testing.expect(queue.commit(8));
        try std.testing.expectEqual(@as(usize, 8), queue.observe(last, true));
    }
    try std.testing.expectEqual(@as(usize, 0), queue.producer);
    try std.testing.expectEqual(@as(?usize, 0), queue.descriptorAt(0));
}

test "output reservation follows retained resampler phase" {
    const std = @import("std");
    try std.testing.expectEqual(@as(?usize, 1), plannedOutputFrames(1, 192_000, 48_000, 0));
    try std.testing.expectEqual(@as(?usize, 0), plannedOutputFrames(1, 192_000, 48_000, 196_608));
    try std.testing.expectEqual(@as(?usize, 480), plannedOutputFrames(480, 48_000, 48_000, 0));
}
