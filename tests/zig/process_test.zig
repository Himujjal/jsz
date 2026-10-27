const std = @import("std");
const jsz = @import("jsz");
const helpers = @import("helpers.zig");
const exe = @import("test_options").jsz_exe;

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

test "process.argv[1] is the absolute script path" {
    const allocator = std.testing.allocator;
    // `std.fs.path.resolveAlloc` keeps relative input relative in Zig 0.17, so
    // anchor the fixture path to the real cwd like the CLI does.
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const script = try std.fs.path.join(allocator, &.{ cwd, helpers.fixture_dir, "process/argv-absolute.js" });
    defer allocator.free(script);

    const result = try helpers.runFixtureProcess(allocator, "process/argv-absolute.js", .{
        .argv = &.{ "jsz", script, "one", "two" },
    });
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(
        \\absolute=true
        \\file=true
        \\tail=one,two
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

test "process.stdout.write is flushed before process.exit" {
    const allocator = std.testing.allocator;
    const result = try helpers.runFixtureProcess(allocator, "process/exit-write.js", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("written\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 3), result.exit_code);
}

test "process.stdout and process.stderr share the captured output" {
    const allocator = std.testing.allocator;
    const actual = try helpers.runFixtureStdout(allocator, "process/streams.js");
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\out-1
        \\err-1
        \\out-2
        \\cb
        \\hi
        \\return=true:true
        \\tty=false
        \\size=number:number
        \\invalid=true
        \\callback
        \\
    , actual);
}

test "process exposes execPath, memoryUsage, umask, title, nextTick, warnings" {
    const allocator = std.testing.allocator;
    const actual = try helpers.runFixtureStdout(allocator, "process/extras.js");
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\exec-argv=true
        \\exec-path=true
        \\memory=true
        \\umask=true
        \\umask-restored=true
        \\title=jsz-phase3a
        \\warning="(node:PID) [JSZ001] CustomWarning: careful\n"
        \\warning-default="(node:PID) Warning: bare\n"
        \\order=xy,promise
        \\
    , actual);
}

test "execPath resolves to an absolute path through runFixture" {
    const allocator = std.testing.allocator;
    const actual = try helpers.runFixture(allocator, "process/extras.js");
    defer allocator.free(actual);

    try std.testing.expectEqualStrings("exec-ok", actual);
}

test "process.on('exit') runs once on normal exhaustion" {
    const allocator = std.testing.allocator;
    const result = try helpers.runFixtureProcess(allocator, "process/exit-listener.js", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("exit 0\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "process.exit(code) hands the code to exit listeners" {
    const allocator = std.testing.allocator;
    const result = try helpers.runFixtureProcess(allocator, "process/exit-listener-code.js", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("exit 3\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 3), result.exit_code);
}

test "process.exitCode drives the normal exhaustion path" {
    const allocator = std.testing.allocator;
    const result = try helpers.runFixtureProcess(allocator, "process/exit-code-property.js", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("before=0\nafter=4\n", result.stdout);
    try std.testing.expectEqual(@as(u8, 4), result.exit_code);
}

test "exit listeners support once, off, and removeAllListeners" {
    const allocator = std.testing.allocator;
    const result = try helpers.runFixtureProcess(allocator, "process/listeners.js", .{});
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(
        \\count-1=1
        \\count-2=3
        \\count-3=0
        \\once:0,once:1
        \\count-exit=1
        \\code=0
        \\
    , result.stdout);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "uncaughtException listener keeps the loop alive" {
    const allocator = std.testing.allocator;
    const result = try helpers.runFixtureProcess(allocator, "process/uncaught-exception.js", .{});
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Error: boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "caught boom\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "alive=1\n") != null);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

test "unhandled rejections are reported at shutdown" {
    const allocator = std.testing.allocator;
    const result = try helpers.runFixtureProcess(allocator, "process/unhandled-rejection.js", .{});
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(
        u8,
        result.stdout,
        "UnhandledPromiseRejectionWarning: Error: boom\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "alive\n") != null);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
}

test "exit listeners run after a top-level error" {
    const allocator = std.testing.allocator;
    const script = try std.fs.path.resolveAlloc(allocator, &.{ helpers.fixture_dir, "process/exit-after-error.js" });
    defer allocator.free(script);

    const result = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ exe, script } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try expectCleanExit(result.term, 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "exit 1\n") != null);
}

test "uncaughtException covers a top-level throw" {
    const allocator = std.testing.allocator;
    const script = try std.fs.path.resolveAlloc(allocator, &.{ helpers.fixture_dir, "process/top-level-uncaught.js" });
    defer allocator.free(script);

    const result = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ exe, script } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try expectCleanExit(result.term, 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "caught boom\n") != null);
}

test "promise continuations run when fs work settles at loop exhaustion" {
    const allocator = std.testing.allocator;
    const runtime = try helpers.initRuntime(null);
    defer runtime.deinit();

    const script = try std.fs.path.join(allocator, &.{ helpers.fixture_dir, "process/loop-liveness.js" });
    defer allocator.free(script);

    const value = try runtime.evalFile(script);
    value.deinit(runtime.context());

    // Let the read finish outside the loop: the first dispatch settles it on
    // the same iteration the loop decides it has no work left.
    var waited: usize = 0;
    while (runtime.loop.fs.?.queue.hasPending()) : (waited += 1) {
        if (waited == 2000) return error.FsJobNeverCompleted;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }

    try runtime.run();

    const result = try helpers.readResult(allocator, runtime);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("done", result);
}

const SigintResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,

    fn deinit(self: SigintResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
    }
};

/// Runs a fixture with stdout captured in a file, sends SIGINT after the
/// listener had time to install, and reaps the child. The fixture's own guard
/// timer keeps a broken watcher from hanging the test.
fn runWithSigint(allocator: std.mem.Allocator, name: []const u8) !SigintResult {
    const script = try std.fs.path.resolveAlloc(allocator, &.{ helpers.fixture_dir, name });
    defer allocator.free(script);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_file = try tmp.dir.createFile(std.testing.io, "stdout.txt", .{});
    var child = try std.process.spawn(std.testing.io, .{
        .argv = &.{ exe, script },
        .stdin = .ignore,
        .stdout = .{ .file = out_file },
        .stderr = .ignore,
    });
    out_file.close(std.testing.io);

    try std.Io.sleep(std.testing.io, .fromMilliseconds(300), .awake);

    const term = blk: {
        const pid = child.id orelse return error.MissingChildPid;
        try std.posix.kill(pid, std.posix.SIG.INT);
        break :blk try child.wait(std.testing.io);
    };

    const read_file = try tmp.dir.openFile(std.testing.io, "stdout.txt", .{});
    defer read_file.close(std.testing.io);
    var buffer: [4096]u8 = undefined;
    var reader = read_file.reader(std.testing.io, &buffer);
    const stdout = try reader.interface.allocRemaining(allocator, .limited(1 << 20));

    return .{ .term = term, .stdout = stdout };
}

fn expectCleanExit(term: std.process.Child.Term, expected: u8) !void {
    switch (term) {
        .exited => |code| try std.testing.expectEqual(expected, code),
        else => return error.UnexpectedTerm,
    }
}

test "SIGINT runs the JS listener and keeps the loop alive" {
    const allocator = std.testing.allocator;
    const result = try runWithSigint(allocator, "process/sigint.js");
    defer result.deinit(allocator);

    try expectCleanExit(result.term, 0);
    try std.testing.expectEqualStrings("ready\nsigint\nafter\n", result.stdout);
}

test "SIGINT without a listener exits 130" {
    const allocator = std.testing.allocator;
    const result = try runWithSigint(allocator, "process/sigint-default.js");
    defer result.deinit(allocator);

    try expectCleanExit(result.term, 130);
    try std.testing.expectEqualStrings("ready\n", result.stdout);
}
