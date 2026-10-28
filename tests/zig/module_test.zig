const std = @import("std");
const helpers = @import("helpers.zig");

test "import.meta exposes url and main for entry and dependency" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "modules/meta.mjs");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\url-scheme=true
        \\url-absolute=true
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

test "dynamic import works from entry, timer, microtask, and file URLs" {
    const result = try helpers.runFixtureProcess(std.testing.allocator, "modules/dynamic.mjs", .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings(
        \\top=42 default=6 same=true static=42
        \\tla=before,after
        \\builtin=a/b alias=true
        \\file-url=42 same=true
        \\space=space
        \\dir=index
        \\missing=Error:ERR_MODULE_NOT_FOUND
        \\unknown-builtin=Error:ERR_UNKNOWN_BUILTIN_MODULE
        \\package=Error:ERR_MODULE_NOT_FOUND
        \\scheme=Error:ERR_UNSUPPORTED_ESM_URL_SCHEME
        \\throws=Error:boom
        \\tla-throws=tla-boom
        \\syntax=SyntaxError
        \\microtask=after
        \\timer=42 same=true
        \\timer-throws=boom
        \\
    , result.stdout);
}

test "caught dynamic import of a throwing module is not reported as unhandled" {
    const result = try helpers.runFixtureProcess(std.testing.allocator, "modules/dynamic.mjs", .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "UnhandledPromiseRejectionWarning") == null);
}

test "uncaught dynamic import rejection is reported and exits 1" {
    const result = try helpers.runFixtureProcess(std.testing.allocator, "modules/dynamic-uncaught.mjs", .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result.stdout,
        "UnhandledPromiseRejectionWarning: Error: boom",
    ) != null);
    // The internal module-evaluation promise must not be reported as well.
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, result.stdout, "UnhandledPromiseRejectionWarning"),
    );
}

test "dynamic import from a CommonJS script resolves relative to the script" {
    const result = try helpers.runFixtureProcess(std.testing.allocator, "modules/dynamic-script.cjs", .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("script=42\n", result.stdout);
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
