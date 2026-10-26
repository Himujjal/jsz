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
