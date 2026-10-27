const std = @import("std");
const helpers = @import("helpers.zig");

fn expectFixture(name: []const u8, expected: []const u8) !void {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, name);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "process.exit skips handlers for work still queued" {
    const allocator = std.testing.allocator;
    const result = try helpers.runFixtureProcess(allocator, "async/exit_with_pending_job.mjs", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("before\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 7), result.exit_code);
}

test "job completions interleave with timers" {
    try expectFixture("async/timers_during_io.mjs",
        \\probe=true:true
        \\reads=100
        \\complete=true
        \\ticks-during=true
        \\cleanup=true
        \\
    );
}

test "loop exits once the last awaited job settles" {
    try expectFixture("async/sequential.mjs",
        \\first=true
        \\second=true
        \\done
        \\
    );
}

test "chdir refreshes host.cwd to an absolute path" {
    const allocator = std.testing.allocator;
    const runtime = try helpers.initRuntime(null);
    defer runtime.deinit();

    const original = try allocator.dupe(u8, runtime.host.cwd);
    defer allocator.free(original);
    // The cwd is process-global, so restore it even if an assertion fails.
    defer std.process.setCurrentPath(std.testing.io, original) catch {};

    try std.testing.expect(std.fs.path.isAbsolute(original));

    const value = try runtime.eval("process.chdir('tests'); globalThis.__result = process.cwd();", "<test>");
    value.deinit(runtime.context());

    try std.testing.expect(std.mem.endsWith(u8, runtime.host.cwd, "/tests"));
    try std.testing.expect(std.fs.path.isAbsolute(runtime.host.cwd));

    const reported = try helpers.readResult(allocator, runtime);
    defer allocator.free(reported);
    try std.testing.expectEqualStrings(runtime.host.cwd, reported);
}

test "ref and unref saturate at zero" {
    const runtime = try helpers.initRuntime(null);
    defer runtime.deinit();

    try std.testing.expect(!runtime.loop.hasRefs());

    runtime.loop.ref();
    runtime.loop.ref();
    try std.testing.expect(runtime.loop.hasRefs());

    runtime.loop.unref();
    try std.testing.expect(runtime.loop.hasRefs());
    runtime.loop.unref();
    runtime.loop.unref();
    try std.testing.expect(!runtime.loop.hasRefs());
}
