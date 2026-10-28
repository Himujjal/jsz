const std = @import("std");
const helpers = @import("helpers.zig");

test "http server fixture" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "http/server.mjs");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\listening IPv4 true
        \\echo 201 POST /echo hello yes
        \\echo-body POST /echo hello yes
        \\second 200 GET /two  none
        \\closed
        \\
    , actual);
}

test "http server shutdown with a live listener" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "http/shutdown.mjs");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("start\n", actual);
}

test "http server close drains an in-flight response" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "http/close_drain.mjs");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("body drained\nclosed\n", actual);
}

test "http client request and get" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "http/request.mjs");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(
        \\200 POST /echo:hello world
        \\/get:
        \\closed
        \\
    , actual);
}

test "http server streams chunks and keeps the status line" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "http/stream.mjs");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(
        \\stream-chunked true
        \\stream-body one-two-three
        \\status-line HTTP/1.1 599 Custom Reason
        \\length-body 5
        \\length-chunked false
        \\drain true
        \\drain-body 131072
        \\closed
        \\
    , actual);
}

test "https server binds with a PEM certificate" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "https/server.mjs");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(
        \\listening IPv4 true
        \\server true
        \\closed
        \\
    , actual);
}

test "https client handshake, streaming body, and insecure request" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "https/handshake.mjs");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(
        \\secure 200 secure
        \\stream 200 abc
        \\bulk 200 24576 true
        \\insecure 200 secure
        \\closed
        \\
    , actual);
}

test "https mutual TLS and pfx certificates" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "https/mtls.mjs");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(
        \\mtls 200 secure
        \\mtls-ca-array 200 secure
        \\mtls-pfx 200 secure
        \\mtls-missing true
        \\pfx-server 200 secure
        \\pfx-wrong ERR_INVALID_PASSWORD
        \\closed
        \\
    , actual);
}
