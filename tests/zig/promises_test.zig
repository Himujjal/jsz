const std = @import("std");
const helpers = @import("helpers.zig");

test "Promise.all resolves values" {
    const runtime = try helpers.initRuntime(null);
    defer runtime.deinit();

    const value = try runtime.eval(
        \\globalThis.__result = "";
        \\Promise.all([Promise.resolve(1), Promise.resolve(2)])
        \\    .then((values) => { globalThis.__result = values.join("+"); });
    , "<test>");
    value.deinit(runtime.context());

    try runtime.run();

    const result = try helpers.readResult(std.testing.allocator, runtime);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1+2", result);
}

test "sleep returns a host-created promise" {
    const runtime = try helpers.initRuntime(null);
    defer runtime.deinit();

    const value = try runtime.eval(
        \\globalThis.__result = "";
        \\async function main() {
        \\    await sleep(1);
        \\    globalThis.__result = "slept";
        \\}
        \\main();
    , "<test>");
    value.deinit(runtime.context());

    try runtime.run();

    const result = try helpers.readResult(std.testing.allocator, runtime);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("slept", result);
}

test "sleep chains resolve in order" {
    const runtime = try helpers.initRuntime(null);
    defer runtime.deinit();

    const value = try runtime.eval(
        \\globalThis.__result = "";
        \\async function main() {
        \\    await sleep(1);
        \\    globalThis.__result += "a";
        \\    await sleep(1);
        \\    globalThis.__result += "b";
        \\}
        \\main();
    , "<test>");
    value.deinit(runtime.context());

    try runtime.run();

    const result = try helpers.readResult(std.testing.allocator, runtime);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("ab", result);
}
