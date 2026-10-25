const std = @import("std");
const jsz = @import("jsz");
const helpers = @import("helpers.zig");

test "microtasks run before timers" {
    const runtime = try helpers.initRuntime(null);
    defer runtime.deinit();

    const value = try runtime.eval(
        \\globalThis.__result = "";
        \\setTimeout(() => { globalThis.__result += "b"; }, 0);
        \\Promise.resolve().then(() => { globalThis.__result += "m"; });
    , "<test>");
    value.deinit(runtime.context());

    try runtime.run();

    const result = try helpers.readResult(std.testing.allocator, runtime);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("mb", result);
}

test "timeout callbacks receive extra arguments" {
    const runtime = try helpers.initRuntime(null);
    defer runtime.deinit();

    const value = try runtime.eval(
        \\globalThis.__result = "";
        \\setTimeout((a, b) => { globalThis.__result = a + b; }, 0, "a", "b");
    , "<test>");
    value.deinit(runtime.context());

    try runtime.run();

    const result = try helpers.readResult(std.testing.allocator, runtime);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("ab", result);
}

test "clearTimeout prevents a callback" {
    const runtime = try helpers.initRuntime(null);
    defer runtime.deinit();

    const value = try runtime.eval(
        \\globalThis.__result = "kept";
        \\const id = setTimeout(() => { globalThis.__result = "fired"; }, 0);
        \\clearTimeout(id);
    , "<test>");
    value.deinit(runtime.context());

    try runtime.run();

    const result = try helpers.readResult(std.testing.allocator, runtime);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("kept", result);
}

test "interval stops when cleared" {
    const runtime = try helpers.initRuntime(null);
    defer runtime.deinit();

    const value = try runtime.eval(
        \\globalThis.__result = "";
        \\let count = 0;
        \\const id = setInterval(() => {
        \\    count += 1;
        \\    if (count === 3) {
        \\        clearInterval(id);
        \\        globalThis.__result = "ticks=" + count;
        \\    }
        \\}, 1);
    , "<test>");
    value.deinit(runtime.context());

    try runtime.run();

    const result = try helpers.readResult(std.testing.allocator, runtime);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("ticks=3", result);
}

test "interval hits the iteration guard" {
    const runtime = try jsz.Runtime.init(std.testing.allocator, .{
        .max_iterations = 5,
        .max_runtime_ms = 1_000,
    });
    defer runtime.deinit();

    const value = try runtime.eval("setInterval(() => {}, 1);", "<test>");
    value.deinit(runtime.context());

    try std.testing.expectError(error.Timeout, runtime.run());
}
