const std = @import("std");
const helpers = @import("helpers.zig");

/// Produced by `node tests/fixtures/path.js`. jsz must reproduce it byte for
/// byte; the fixture was itself diffed against Node 22.
const expected_path = @import("test_options").path_expected;

test "node:path fixture matches Node output" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "path.js");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected_path, actual);
}

test "relative ESM imports and builtin aliases" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "modules/main.mjs");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(
        \\value=dep
        \\double=42
        \\join=/a/b
        \\alias_same=true
        \\
    , actual);
}

test ".js with export syntax is auto-detected as a module" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "modules/auto.js");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("auto=c.txt\n", actual);
}

test "missing builtin reports a module error" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    const runtime = try helpers.initRuntime(&writer.writer);
    defer runtime.deinit();

    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ helpers.fixture_dir, "modules/missing.mjs" },
    );
    defer std.testing.allocator.free(path);

    const value = runtime.evalFile(path) catch |err| {
        try std.testing.expectEqual(error.JavaScriptError, err);
        return;
    };
    value.deinit(runtime.context());
    return error.ExpectedJavaScriptError;
}
