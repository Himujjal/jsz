const std = @import("std");
const helpers = @import("helpers.zig");

test "node:os reports host facts without throwing" {
    const allocator = std.testing.allocator;
    const actual = try helpers.runFixtureStdout(allocator, "os.js");
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\platform=true
        \\arch=true
        \\type=true
        \\release=true
        \\version=true
        \\machine=true
        \\hostname=true
        \\homedir=true
        \\tmpdir=true
        \\eol=true
        \\devnull=true
        \\cpus=true
        \\cpu-shape=true
        \\parallel=true
        \\uptime=true
        \\loadavg=true
        \\user=true
        \\totalmem=true
        \\default=true
        \\
    , actual);
}

test "node:os reads homedir, tmpdir, and userInfo from the environment" {
    const allocator = std.testing.allocator;
    const result = try helpers.runFixtureProcess(allocator, "os-env.js", .{
        .env = &.{
            .{ "HOME", "/tmp/jsz-home" },
            .{ "TMPDIR", "/tmp/jsz-tmp/" },
            .{ "USER", "tester" },
            .{ "SHELL", "/bin/sh" },
        },
    });
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(
        \\home=/tmp/jsz-home
        \\tmp=/tmp/jsz-tmp
        \\user=tester
        \\shell=/bin/sh
        \\
    , result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "cpus() reports a non-empty list through runFixture" {
    const allocator = std.testing.allocator;
    const actual = try helpers.runFixture(allocator, "os.js");
    defer allocator.free(actual);

    try std.testing.expectEqualStrings("cpus-ok", actual);
}
