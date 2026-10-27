const std = @import("std");
const helpers = @import("helpers.zig");

test "import.meta exposes url and main for entry and dependency" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "modules/meta.mjs");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\url-scheme=true
        \\url-suffix=true
        \\main=true
        \\dep-main=false
        \\dep-url=true
        \\
    , actual);
}

test "relative ESM imports support a cycle with live bindings" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "modules/cycle/main.mjs");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\a=abc
        \\c=c
        \\peek=abc
        \\main=true
        \\
    , actual);
}

test "private node:_ specifiers are rejected from user modules" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    const runtime = try helpers.initRuntime(&writer.writer);
    defer runtime.deinit();

    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ helpers.fixture_dir, "modules/private.mjs" },
    );
    defer std.testing.allocator.free(path);

    const value = runtime.evalFile(path) catch |err| {
        try std.testing.expectEqual(error.JavaScriptError, err);
        try runtime.flush();
        try std.testing.expect(std.mem.indexOf(u8, writer.written(), "Cannot import private module") != null);
        return;
    };
    value.deinit(runtime.context());
    return error.ExpectedJavaScriptError;
}
