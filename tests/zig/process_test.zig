const std = @import("std");
const jsz = @import("jsz");
const helpers = @import("helpers.zig");

test "process.argv includes the script path and trailing args" {
    const allocator = std.testing.allocator;
    const script = try std.fs.path.resolveAlloc(allocator, &.{ helpers.fixture_dir, "process/argv.js" });
    defer allocator.free(script);

    const result = try helpers.runFixtureProcess(allocator, "process/argv.js", .{
        .argv = &.{ "jsz", script, "alpha", "beta" },
    });
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(
        \\len=4
        \\script=argv.js
        \\tail=alpha,beta
        \\exe=true
        \\
    , result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "eval argv omits the script path" {
    const allocator = std.testing.allocator;
    const runtime = try jsz.Runtime.init(allocator, .{
        .argv = &.{ "jsz", "alpha", "beta" },
        .max_iterations = 10_000,
        .max_runtime_ms = 5_000,
    });
    defer runtime.deinit();

    const value = try runtime.eval(
        \\globalThis.__result = process.argv.join(",");
    , "<test>");
    value.deinit(runtime.context());
    try runtime.run();

    const result = try helpers.readResult(allocator, runtime);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("jsz,alpha,beta", result);
}

test "process.cwd and process.chdir round-trip" {
    const allocator = std.testing.allocator;
    const result = try helpers.runFixtureProcess(allocator, "process/cwd.js", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(
        \\absolute=true
        \\moved=true
        \\restored=true
        \\
    , result.stdout);
}

test "process.chdir reports a Node-shaped ENOENT" {
    const allocator = std.testing.allocator;
    const result = try helpers.runFixtureProcess(allocator, "process/cwd-error.js", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(
        \\threw=true
        \\code=ENOENT
        \\syscall=chdir
        \\dest=does-not-exist
        \\path=true
        \\message=true
        \\
    , result.stdout);
}

test "process.env reads, mutates, and deletes" {
    const allocator = std.testing.allocator;
    const result = try helpers.runFixtureProcess(allocator, "process/env.js", .{
        .env = &.{.{ "JSZ_TEST_ENV", "inherited" }},
    });
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(
        \\inherit=inherited
        \\set=one
        \\overwrite=two
        \\undefined=undefined
        \\deleted=undefined
        \\missing=undefined
        \\
    , result.stdout);
}

test "process.hrtime is monotonic and supports bigint" {
    const allocator = std.testing.allocator;
    const result = try helpers.runFixtureProcess(allocator, "process/hrtime.js", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(
        \\shape=true
        \\nanos=true
        \\diff-seconds=0
        \\diff-positive=true
        \\monotonic=true
        \\bigint=true
        \\
    , result.stdout);
}

test "process.uptime reports runtime age" {
    const allocator = std.testing.allocator;
    const result = try helpers.runFixtureProcess(allocator, "process/uptime.js", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(
        \\type=number
        \\positive=true
        \\bounded=true
        \\
    , result.stdout);
}

test "process identity and default export" {
    const allocator = std.testing.allocator;
    const result = try helpers.runFixtureProcess(allocator, "process/identity.js", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(
        \\pid=true
        \\ppid=true
        \\platform=true
        \\arch=true
        \\version=true
        \\versions=true
        \\global=true
        \\default=true
        \\
    , result.stdout);
}

test "process.exit sets the code and stops pending timers" {
    const allocator = std.testing.allocator;
    const result = try helpers.runFixtureProcess(allocator, "process/exit-code.js", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("before\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 3), result.exit_code);
}
