const std = @import("std");
const helpers = @import("helpers.zig");

test "timers fixture" {
    const result = try helpers.runFixture(std.testing.allocator, "timers.js");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("mbcad", result);
}

test "intervals fixture" {
    const result = try helpers.runFixture(std.testing.allocator, "intervals.js");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("ticks=3", result);
}

test "promises fixture" {
    const result = try helpers.runFixture(std.testing.allocator, "promises.js");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1+2", result);
}

test "async await fixture" {
    const result = try helpers.runFixture(std.testing.allocator, "async_await.js");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("slept", result);
}

test "promise wrapped setTimeout sleep" {
    const result = try helpers.runFixture(std.testing.allocator, "sleep_promise.js");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("ab", result);
}

test "timer longer than the i32 nanosecond range fires on time" {
    const result = try helpers.runFixture(std.testing.allocator, "long_timer.js");
    defer std.testing.allocator.free(result);

    const elapsed = try std.fmt.parseInt(u64, result["elapsed=".len..], 10);
    try std.testing.expect(elapsed >= 2_190);
}

test "uncaught timer errors stop the loop" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    const runtime = try helpers.initRuntime(&writer.writer);
    defer runtime.deinit();

    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ helpers.fixture_dir, "errors.js" },
    );
    defer std.testing.allocator.free(path);

    const value = try runtime.evalFile(path);
    value.deinit(runtime.context());

    try std.testing.expectError(error.JavaScriptError, runtime.run());
    try runtime.flush();
    try std.testing.expect(std.mem.indexOf(u8, writer.written(), "boom") != null);
}
