const std = @import("std");
const exe = @import("test_options").jsz_exe;

fn run(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.RunResult {
    return std.process.run(allocator, std.testing.io, .{ .argv = argv });
}

fn expectExit(result: std.process.RunResult, expected: u8) !void {
    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(expected, code),
        else => return error.UnexpectedTerm,
    }
}

test "cli resolves the script path and forwards trailing arguments" {
    const allocator = std.testing.allocator;
    const script = try std.fs.path.resolveAlloc(allocator, &.{"tests/fixtures/process/argv.js"});
    defer allocator.free(script);

    const result = try run(allocator, &.{ exe, script, "alpha", "beta" });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try expectExit(result, 0);
    try std.testing.expectEqualStrings(
        \\len=4
        \\script=argv.js
        \\tail=alpha,beta
        \\exe=true
        \\
    , result.stdout);
}

test "cli eval keeps trailing arguments as the argv tail" {
    const allocator = std.testing.allocator;
    const result = try run(allocator, &.{
        exe, "-e", "console.log(process.argv.slice(1).join(','))", "alpha", "beta",
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try expectExit(result, 0);
    try std.testing.expectEqualStrings("alpha,beta\n", result.stdout);
}

test "cli eval auto-detects module syntax" {
    const allocator = std.testing.allocator;
    const result = try run(allocator, &.{
        exe, "-e", "import { join } from 'node:path'; import os from 'node:os'; console.log(join('a', 'b')); console.log(typeof os.cpus().length)",
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try expectExit(result, 0);
    try std.testing.expectEqualStrings("a/b\nnumber\n", result.stdout);
}

test "cli eval supports dynamic import relative to cwd" {
    const allocator = std.testing.allocator;
    const result = try run(allocator, &.{
        exe,
        "-e",
        "import('./tests/fixtures/modules/dynamic-dep.mjs').then((m) => console.log('eval=' + m.value));",
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try expectExit(result, 0);
    try std.testing.expectEqualStrings("eval=42\n", result.stdout);
}

test "cli propagates the process.exit code after flushing stdout" {
    const allocator = std.testing.allocator;
    const script = try std.fs.path.resolveAlloc(allocator, &.{"tests/fixtures/process/exit-code.js"});
    defer allocator.free(script);

    const result = try run(allocator, &.{ exe, script });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try expectExit(result, 3);
    try std.testing.expectEqualStrings("before\n", result.stdout);
}
