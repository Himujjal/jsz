const std = @import("std");
const jsz = @import("jsz");
const helpers = @import("helpers.zig");

const jobs = jsz.jobs;

const Recorder = struct {
    settled: [8]usize = undefined,
    settled_count: usize = 0,
    aborted: usize = 0,
};

const Fake = struct {
    recorder: *Recorder,
    id: usize,
    job: jobs.Job = undefined,

    fn init(self: *Fake, recorder: *Recorder, id: usize) void {
        self.recorder = recorder;
        self.id = id;
        self.job = .{
            .context = self,
            .settle = settle,
            .abort = abort,
        };
    }

    fn settle(_: *jsz.Context, job: *jobs.Job) void {
        const self: *Fake = @ptrCast(@alignCast(job.context));
        self.recorder.settled[self.recorder.settled_count] = self.id;
        self.recorder.settled_count += 1;
    }

    fn abort(_: *jsz.Context, job: *jobs.Job) void {
        const self: *Fake = @ptrCast(@alignCast(job.context));
        self.recorder.aborted += 1;
    }
};

test "queue tracks work and dispatches completions in order" {
    const runtime = try helpers.initRuntime(null);
    defer runtime.deinit();

    var recorder: Recorder = .{};
    var fakes: [3]Fake = undefined;
    var queue = jobs.Queue.init(std.testing.allocator);
    defer queue.deinit();

    try std.testing.expect(!queue.hasWork());

    for (&fakes, 0..) |*fake, index| {
        fake.init(&recorder, index);
        try queue.submit(&fake.job);
    }

    try std.testing.expect(queue.hasWork());
    try std.testing.expect(queue.hasPending());
    try std.testing.expect(queue.tryTake() == null);

    for (&fakes) |*fake| queue.complete(&fake.job);

    try std.testing.expect(queue.hasWork());
    try std.testing.expect(!queue.hasPending());

    queue.dispatch(runtime.context());

    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, recorder.settled[0..recorder.settled_count]);
    try std.testing.expect(!queue.hasWork());
    try std.testing.expectEqual(@as(usize, 0), recorder.aborted);
}

test "wait returns immediately when idle or already complete" {
    var recorder: Recorder = .{};
    var fake: Fake = undefined;
    fake.init(&recorder, 0);

    var queue = jobs.Queue.init(std.testing.allocator);
    defer queue.deinit();

    queue.wait(0);
    queue.wait(1);

    try queue.submit(&fake.job);
    queue.complete(&fake.job);
    queue.wait(null);
    try std.testing.expect(queue.tryTake() != null);
}

test "cancel rolls back a submit whose task never started" {
    var recorder: Recorder = .{};
    var fake: Fake = undefined;
    fake.init(&recorder, 0);

    var queue = jobs.Queue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.submit(&fake.job);
    try std.testing.expect(queue.hasPending());

    queue.cancel();
    try std.testing.expect(!queue.hasWork());
    try std.testing.expect(!queue.hasPending());
}

test "double cancel neither wraps pending nor stalls shutdown" {
    const runtime = try helpers.initRuntime(null);
    defer runtime.deinit();

    var recorder: Recorder = .{};
    var fake: Fake = undefined;
    fake.init(&recorder, 0);

    var queue = jobs.Queue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.submit(&fake.job);
    queue.cancel();
    // A retried teardown cancels again; a wrapping `-=` would make this huge.
    queue.cancel();

    try std.testing.expect(!queue.hasPending());
    try std.testing.expect(!queue.hasWork());

    // A wrapped counter would keep shutdown waiting for work that already ended.
    queue.shutdown(runtime.context());
    try std.testing.expect(!queue.hasWork());
    try std.testing.expectError(error.Closed, queue.submit(&fake.job));
}

test "shutdown aborts queued completions and refuses new work" {
    const runtime = try helpers.initRuntime(null);
    defer runtime.deinit();

    var recorder: Recorder = .{};
    var first: Fake = undefined;
    var second: Fake = undefined;
    first.init(&recorder, 0);
    second.init(&recorder, 1);

    var queue = jobs.Queue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.submit(&first.job);
    queue.complete(&first.job);

    queue.shutdown(runtime.context());

    try std.testing.expectEqual(@as(usize, 1), recorder.aborted);
    try std.testing.expectEqual(@as(usize, 0), recorder.settled_count);
    try std.testing.expect(!queue.hasWork());
    try std.testing.expectError(error.Closed, queue.submit(&second.job));
}
