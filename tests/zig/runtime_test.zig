const std = @import("std");
const jsz = @import("jsz");
const helpers = @import("helpers.zig");

test "evaluates arithmetic" {
    const runtime = try helpers.initRuntime(null);
    defer runtime.deinit();

    const value = try runtime.eval("1 + 1", "<test>");
    defer value.deinit(runtime.context());

    try std.testing.expectEqual(@as(i32, 2), try value.toInt32(runtime.context()));
}

test "reports syntax errors" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const runtime = try helpers.initRuntime(&output.writer);
    defer runtime.deinit();

    try std.testing.expectError(
        error.JavaScriptError,
        runtime.eval("function {", "<test>"),
    );
    try runtime.flush();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "SyntaxError") != null);
}

test "runs pending promise jobs" {
    const runtime = try helpers.initRuntime(null);
    defer runtime.deinit();

    const value = try runtime.eval(
        \\globalThis.__result = "";
        \\Promise.resolve().then(() => { globalThis.__result = "job"; });
    , "<test>");
    value.deinit(runtime.context());

    try runtime.run();

    const result = try helpers.readResult(std.testing.allocator, runtime);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("job", result);
}

test "rejects invalid timeout callbacks" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const runtime = try helpers.initRuntime(&output.writer);
    defer runtime.deinit();

    try std.testing.expectError(
        error.JavaScriptError,
        runtime.eval("setTimeout(42, 0);", "<test>"),
    );
    try runtime.flush();
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "callback must be a function") != null);
}

test "version is exported" {
    try std.testing.expect(jsz.version.len > 0);
}
