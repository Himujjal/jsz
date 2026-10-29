const std = @import("std");
const builtin = @import("builtin");
const jsz = @import("jsz");
const helpers = @import("helpers.zig");
const exe = @import("test_options").jsz_exe;

test "electron is unavailable outside desktop mode" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "electron/disabled.mjs");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\electron=ERR_DESKTOP_NOT_ENABLED
        \\node=ERR_UNKNOWN_BUILTIN_MODULE
        \\
    , actual);
}

test "desktop main role exposes only the main-process surface" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    const path = try std.fs.path.join(
        std.testing.allocator,
        &.{ helpers.fixture_dir, "electron/main-role.mjs" },
    );
    defer std.testing.allocator.free(path);

    const runtime = try jsz.Runtime.init(std.testing.allocator, .{
        .writer = &writer.writer,
        .max_iterations = 10_000,
        .max_runtime_ms = 5_000,
        .desktop = true,
    });
    defer runtime.deinit();

    const value = try runtime.evalFile(path);
    value.deinit(runtime.context());
    try runtime.run();
    try runtime.flush();

    try std.testing.expectEqualStrings(
        \\app=object
        \\window=function
        \\ipc=function
        \\dialog=function
        \\shell=function
        \\notready=ERR_APP_NOT_READY
        \\option=ERR_ELECTRON_UNSUPPORTED_OPTION
        \\scheme=TypeError
        \\
    , writer.written());
}

test "cli requires a script for desktop mode" {
    const allocator = std.testing.allocator;
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ exe, "--desktop" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 1), code),
        else => return error.UnexpectedTerm,
    }
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "DesktopRequiresScript") != null);
}

test "cli rejects eval in desktop mode" {
    const allocator = std.testing.allocator;
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ exe, "--desktop", "-e", "console.log('nope')" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 1), code),
        else => return error.UnexpectedTerm,
    }
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "DesktopRequiresScript") != null);
}

test "desktop window completes an IPC round trip" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // Visible GUI tests are opt-in so headless CI does not open a window.
    if (std.c.getenv("JSZ_DESKTOP_TESTS") == null) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const script = try std.fs.path.resolveAlloc(
        allocator,
        &.{ helpers.fixture_dir, "electron/main.mjs" },
    );
    defer allocator.free(script);

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ exe, "--desktop", script },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    try std.testing.expectEqualStrings("desktop=ok:hello:true\n", result.stdout);
}
