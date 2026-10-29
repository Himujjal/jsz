const std = @import("std");
const jsz = @import("jsz");
const helpers = @import("helpers.zig");

test "crypto hashes, hmacs, and random helpers match Node vectors" {
    const result = try helpers.runFixture(std.testing.allocator, "crypto.js");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("ok", result);
}

test "createHmac reports ERR_CRYPTO_INVALID_DIGEST while createHash keeps the digest error" {
    const allocator = std.testing.allocator;
    const runtime = try jsz.Runtime.init(allocator, .{
        .max_iterations = 10_000,
        .max_runtime_ms = 5_000,
    });
    defer runtime.deinit();

    const value = try runtime.evalDetected(
        \\import crypto from 'node:crypto';
        \\const lines = [];
        \\try {
        \\  crypto.createHmac('bogus', 'key');
        \\} catch (error) {
        \\  lines.push(`${error.code}|${error.message}`);
        \\}
        \\try {
        \\  crypto.createHash('bogus');
        \\} catch (error) {
        \\  lines.push(`${error.code}|${error.message}`);
        \\}
        \\globalThis.__result = lines.join('\n');
    , "<test>");
    value.deinit(runtime.context());
    try runtime.run();

    const result = try helpers.readResult(allocator, runtime);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        \\ERR_CRYPTO_INVALID_DIGEST|Invalid digest: bogus
        \\ERR_CRYPTO_HASH_UNKNOWN|Digest method not supported
    , result);
}
