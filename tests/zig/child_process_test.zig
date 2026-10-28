const std = @import("std");
const helpers = @import("helpers.zig");

test "sync child_process fixture" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "child_process/sync.mjs");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\basic=0:hi:null:null
        \\exit=3:null:null
        \\missing=ENOENT:null:null
        \\input=0:abc
        \\env=yes
        \\cwd=0:true
        \\exec=hi
        \\exec-file=hi
        \\exec-error=3:true:true:3
        \\maxbuffer=ENOBUFS
        \\maxbuffer-exec=ERR_CHILD_PROCESS_STDIO_MAXBUFFER
        \\ignore=0:null
        \\shell=0:hi
        \\inherit=inherited
        \\
    , actual);
}

test "async child_process fixture" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "child_process/async.mjs");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\spawn=0:null:out:err:number
        \\exec=hi
        \\execFile=file
        \\stdin=0:abc
        \\kill=null:SIGTERM
        \\missing=ENOENT
        \\exit=3:3
        \\inherit=inherited
        \\maxbuffer=ERR_CHILD_PROCESS_STDIO_MAXBUFFER
        \\ignore=0:none
        \\
    , actual);
}

test "stream child_process fixture" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "child_process/streams.mjs");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\pause=pass:2097152
        \\pipe=hello
        \\pipe-drain=backpressure
        \\iterator=4
        \\closed=false:false
        \\stderr=err
        \\
    , actual);
}

test "stdin child_process fixture" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "child_process/stdin.mjs");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\small=true:abc
        \\large=false:204800
        \\huge=false:1048576
        \\writable=false
        \\after-end=false
        \\
    , actual);
}

test "options child_process fixture" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "child_process/options.mjs");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\timeout=SIGKILL
        \\timeout-sync=ETIMEDOUT:SIGKILL
        \\abort=SIGTERM
        \\pre-abort=ABORT_ERR
        \\signal-timeout=SIGTERM
        \\unknown-signal=ERR_UNKNOWN_SIGNAL
        \\kill-zero=true:false
        \\per-stream=ok
        \\options=0:opt
        \\detached=true
        \\ids=skip
        \\
    , actual);
}

test "unref child_process fixture" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const started = std.Io.Clock.awake.now(io);
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "child_process/unref.mjs");
    const elapsed = started.durationTo(std.Io.Clock.awake.now(io));
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings("unref=done\n", actual);
    try std.testing.expect(elapsed.nanoseconds < std.time.ns_per_s);
}

test "events child_process fixture" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "child_process/events.mjs");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\order=spawn<data<exit<close
        \\error-close=error<close:ENOENT
        \\signal=SIGTERM:SIGTERM
        \\sigkill=SIGKILL
        \\shell=hi
        \\cwd-env=true:yes
        \\sync-signal=null:SIGTERM
        \\
    , actual);
}

test "exec_callbacks child_process fixture" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "child_process/exec_callbacks.mjs");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\missing=ENOENT:false:null:0:0
        \\missing-shell=127
        \\exec-error=3:3:null:out:err:3
        \\encoding=utf8:hi
        \\buffer=true:2
        \\execfile-status=4
        \\cwd=true
        \\env=env
        \\maxbuffer=ERR_CHILD_PROCESS_STDIO_MAXBUFFER
        \\timeout=true:SIGKILL
        \\abort=ABORT_ERR:AbortError:true
        \\
    , actual);
}

test "stdin_callbacks child_process fixture" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "child_process/stdin_callbacks.mjs");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\callback=true
        \\stdin=abc
        \\large=false:204800
        \\
    , actual);
}

test "child_process modules are registered" {
    const runtime = try helpers.initRuntime(null);
    defer runtime.deinit();

    const source =
        "import { spawnSync } from 'node:child_process';\n" ++
        "import childProcess from 'node:child_process';\n" ++
        "globalThis.__result = `${typeof spawnSync}:${childProcess.spawnSync === spawnSync}`;\n";
    const value = try runtime.evalDetected(source, "<child-process-test>");
    value.deinit(runtime.context());

    const result = try helpers.readResult(std.testing.allocator, runtime);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("function:true", result);
}
