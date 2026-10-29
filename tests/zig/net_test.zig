const std = @import("std");
const helpers = @import("helpers.zig");

test "net tcp echo fixture" {
    const result = try helpers.runFixtureStdout(std.testing.allocator, "net/tcp.mjs");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        "connected\necho:ping\nserver-closed\n",
        result,
    );
}

test "net connection refused fixture" {
    const result = try helpers.runFixtureStdout(std.testing.allocator, "net/refused.mjs");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        "error:ECONNREFUSED\nclosed:true\n",
        result,
    );
}

test "net destroy while connecting and after connect" {
    const result = try helpers.runFixtureStdout(std.testing.allocator, "net/destroy.mjs");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        "pending-closed:false:false\nconnected\nclosed:false\nserver-closed\n",
        result,
    );
}

test "net sockets report encrypted false" {
    const result = try helpers.runFixtureStdout(std.testing.allocator, "net/encrypted.mjs");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        "client false true\nserver false true\nclosed\n",
        result,
    );
}

test "net close before listen reports ERR_SERVER_NOT_RUNNING" {
    const result = try helpers.runFixtureStdout(std.testing.allocator, "net/close_not_running.mjs");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        "code ERR_SERVER_NOT_RUNNING\nlistening false address null\n",
        result,
    );
}

test "net shutdown with live handles" {
    const result = try helpers.runFixtureStdout(std.testing.allocator, "net/shutdown.mjs");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("start\nexit-with-live-handles\n", result);
}
