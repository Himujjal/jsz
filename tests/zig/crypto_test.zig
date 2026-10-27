const std = @import("std");
const helpers = @import("helpers.zig");

test "crypto hashes, hmacs, and random helpers match Node vectors" {
    const result = try helpers.runFixture(std.testing.allocator, "crypto.js");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("ok", result);
}
