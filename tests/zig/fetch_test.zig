const std = @import("std");
const helpers = @import("helpers.zig");

test "fetch fixture" {
    const result = try helpers.runFixtureStdout(std.testing.allocator, "fetch/fetch.mjs");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        \\text=200 hello fetch
        \\json=true 2
        \\echo=payload-42
        \\header=x-test:hello
        \\missing=404 not found
        \\status=599 Custom Reason weird
        \\redirect=200 hello fetch
        \\
    , result);
}

test "fetch redirect modes, final URL, and abort" {
    const result = try helpers.runFixtureStdout(std.testing.allocator, "fetch/redirect_abort.mjs");
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(
        \\followed 200 true true
        \\error-mode ERR_FETCH_REDIRECT
        \\manual 302 /text
        \\abort AbortError ABORT_ERR
        \\closed
        \\
    , result);
}
