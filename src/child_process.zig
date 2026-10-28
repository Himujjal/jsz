// Async child-process coordinator.
//
// `spawn` returns to the JS task as soon as the OS process exists; one zio task
// then drains stdout/stderr (pipe reads need a zio executor) and reaps the
// process. Every event crosses back to the JS task as a `jobs.Job`, so QuickJS
// values are only ever touched on the JS task.

const std = @import("std");
const builtin = @import("builtin");
const quickjs = @import("quickjs");
const zio = @import("zio");
const jobs = @import("jobs.zig");
const Host = @import("js/host.zig").Host;
const EventLoop = @import("event_loop.zig").EventLoop;

const Value = quickjs.Value;
const StdIo = std.process.SpawnOptions.StdIo;

/// Node's default for `exec*` and `spawnSync`.
pub const default_max_buffer: usize = 1024 * 1024;

/// Options normalized by `child_process.js`; every field is already validated.
pub const Options = struct {
    cwd: ?[]u8 = null,
    env: ?std.process.Environ.Map = null,
    stdin: StdIo = .pipe,
    stdout: StdIo = .pipe,
    stderr: StdIo = .pipe,
    input: ?[]u8 = null,
    max_buffer: usize = default_max_buffer,
    timeout_ms: u64 = 0,
    kill_signal: std.posix.SIG = .TERM,
    uid: ?u32 = null,
    gid: ?u32 = null,
    windows_hide: bool = false,
    detached: bool = false,

    pub fn deinit(self: *Options, allocator: std.mem.Allocator) void {
        if (self.cwd) |path| allocator.free(path);
        if (self.env) |*map| map.deinit();
        if (self.input) |bytes| allocator.free(bytes);
    }
};

pub const Failure = struct {
    code: [:0]const u8,
    errno: i32,
    message: []u8,
    syscall: []u8,

    pub fn deinit(self: *Failure, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.syscall);
    }
};

pub const MappedError = struct {
    code: [:0]const u8,
    errno: i32,
};

pub fn nametoolongErrno() i32 {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit => -63,
        else => -36,
    };
}

pub fn nobufsErrno() i32 {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit => -55,
        else => -105,
    };
}

pub fn mapSpawnError(err: anyerror) MappedError {
    return switch (err) {
        error.FileNotFound => .{ .code = "ENOENT", .errno = -2 },
        error.AccessDenied, error.PermissionDenied => .{ .code = "EACCES", .errno = -13 },
        error.IsDir => .{ .code = "EISDIR", .errno = -21 },
        error.NotDir => .{ .code = "ENOTDIR", .errno = -20 },
        error.InvalidExe => .{ .code = "ENOEXEC", .errno = -8 },
        error.ProcessFdQuotaExceeded => .{ .code = "EMFILE", .errno = -24 },
        error.SystemFdQuotaExceeded => .{ .code = "ENFILE", .errno = -23 },
        error.SystemResources, error.OutOfMemory => .{ .code = "ENOMEM", .errno = -12 },
        error.NameTooLong => .{ .code = "ENAMETOOLONG", .errno = nametoolongErrno() },
        else => .{ .code = "EIO", .errno = -5 },
    };
}

pub fn launchFailure(
    allocator: std.mem.Allocator,
    command: []const u8,
    err: anyerror,
) std.mem.Allocator.Error!Failure {
    const mapped = mapSpawnError(err);
    const message = try std.fmt.allocPrint(allocator, "spawn {s} {s}", .{ command, mapped.code });
    errdefer allocator.free(message);
    const syscall = try std.fmt.allocPrint(allocator, "spawn {s}", .{command});
    return .{
        .code = mapped.code,
        .errno = mapped.errno,
        .message = message,
        .syscall = syscall,
    };
}

/// Releases a job payload that never reached the JS task.
fn freeKind(allocator: std.mem.Allocator, kind: Kind) void {
    switch (kind) {
        .data => |data| allocator.free(data.bytes),
        .spawn_error => |failure| {
            var copy = failure;
            copy.deinit(allocator);
        },
        .end, .exit, .stdin_drain => {},
    }
}

pub const Kind = union(enum) {
    data: struct { stream: u8, bytes: []u8 },
    end: u8,
    exit: std.process.Child.Term,
    spawn_error: Failure,
    stdin_drain: void,
};

/// Bounded hand-off for one output stream: the reader holds a credit from the
/// moment it reads a chunk until the JS task dispatches that chunk.
const StreamFlow = struct {
    mutex: zio.Mutex = .init,
    cond: zio.Condition = .init,
    in_flight: usize = 0,
    limit: usize = 16, // 16 * 16 KiB = 256 KiB per stream
    paused: bool = false,
    closed: bool = false,

    fn acquire(self: *StreamFlow) bool {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        while (!self.closed and (self.paused or self.in_flight >= self.limit)) {
            self.cond.waitUncancelable(&self.mutex);
        }
        if (self.closed) return false;
        self.in_flight += 1;
        return true;
    }

    fn release(self: *StreamFlow) void {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        if (self.in_flight > 0) self.in_flight -= 1;
        self.cond.signal();
    }

    fn pause(self: *StreamFlow) void {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        self.paused = true;
    }

    fn @"resume"(self: *StreamFlow) void {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        self.paused = false;
        self.cond.broadcast();
    }

    fn close(self: *StreamFlow) void {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        self.closed = true;
        self.cond.broadcast();
    }

    /// `zio.Mutex`/`zio.Condition` own no OS resources, so nothing to release.
    fn deinit(_: *StreamFlow) void {}
};

/// Bounded stdin hand-off to the writer task. The JS thread enqueues copies; the
/// writer owns the pipe and drains the chunks in order.
const StdinQueue = struct {
    mutex: zio.Mutex = .init,
    cond: zio.Condition = .init,
    chunks: std.ArrayList([]u8) = .empty,
    bytes: usize = 0,
    limit: usize = 64 * 1024,
    accepting: bool = true,
    eof: bool = false,
    full: bool = false,

    fn close(self: *StdinQueue) void {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        self.accepting = false;
        self.eof = true;
        self.cond.broadcast();
    }

    fn freeChunks(self: *StdinQueue, allocator: std.mem.Allocator) void {
        for (self.chunks.items) |chunk| allocator.free(chunk);
        self.chunks.deinit(allocator);
        self.chunks = .empty;
        self.bytes = 0;
    }
};

pub const Child = struct {
    id: u64,
    /// POSIX pid; `-1` on Windows and before the spawn completes.
    pid: i32 = -1,
    child: std.process.Child = undefined,
    /// Owned copy of the JS dispatch trampoline; deinit'd on the JS task.
    dispatch: quickjs.Value,
    handle: zio.JoinHandle(void) = undefined,
    /// Owned stdin pipe; `child.stdin` is always nulled so `wait`/`kill`
    /// cleanup cannot close it. The writer task owns it during operation.
    stdin_file: ?std.Io.File = null,
    stdin_queue: StdinQueue = .{},
    stdin_writer: ?zio.JoinHandle(void) = null,
    spawn_error: ?Failure = null,
    spawn_failed: bool = false,
    /// Set by the coordinator right after `wait`; read by `kill`/`deinit`.
    exited: std.atomic.Value(bool) = .init(false),
    /// Mirrors JS `ref()`/`unref()`: whether this child keeps the loop alive.
    refs: bool = true,
    stdout_flow: StreamFlow = .{},
    stderr_flow: StreamFlow = .{},

    fn flow(self: *Child, stream: u8) *StreamFlow {
        return if (stream == 0) &self.stdout_flow else &self.stderr_flow;
    }
};

const ChildJob = struct {
    link: jobs.Job,
    owner: *ChildProcesses,
    id: u64,
    kind: Kind,
};

/// One-shot hand-off from the coordinator task to the blocking JS task.
pub const Signal = struct {
    mutex: zio.os.Mutex = .init(),
    cond: zio.os.Condition = .init(),
    done: bool = false,

    pub fn deinit(self: *Signal) void {
        self.mutex.deinit();
        self.cond.deinit();
    }

    pub fn notify(self: *Signal) void {
        self.mutex.lock();
        self.done = true;
        self.cond.signal();
        self.mutex.unlock();
    }

    pub fn wait(self: *Signal) void {
        self.mutex.lock();
        while (!self.done) self.cond.wait(&self.mutex);
        self.mutex.unlock();
    }
};

pub const SpawnResult = union(enum) {
    ok: struct { id: u64, pid: i32 },
    failure: Failure,
};

pub const ChildProcesses = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    rt: *zio.Runtime,
    queue: *jobs.Queue,
    next_id: u64 = 1,
    map: std.AutoHashMap(u64, *Child),

    pub fn init(
        allocator: std.mem.Allocator,
        rt: *zio.Runtime,
        queue: *jobs.Queue,
    ) ChildProcesses {
        return .{
            .allocator = allocator,
            .io = rt.io(),
            .rt = rt,
            .queue = queue,
            .map = std.AutoHashMap(u64, *Child).init(allocator),
        };
    }

    /// Starts the child and returns once `execve` succeeded or failed; output
    /// arrives later as `data`/`end`/`exit` dispatches.
    pub fn spawn(
        self: *ChildProcesses,
        ctx: *quickjs.Context,
        host: *Host,
        argv: []const []const u8,
        options: *const Options,
        dispatch: Value,
    ) std.mem.Allocator.Error!SpawnResult {
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;

        const rec = try self.allocator.create(Child);
        rec.* = .{
            .id = id,
            .dispatch = dispatch.dup(ctx),
        };

        self.map.put(id, rec) catch |err| {
            rec.dispatch.deinit(ctx);
            self.allocator.destroy(rec);
            return err;
        };

        var signal: Signal = .{};
        defer signal.deinit();

        // `startChild` only borrows `argv`/`options` until it signals us.
        const handle = self.rt.spawn(startChild, .{ self, host, rec, argv, options, &signal }) catch {
            return self.discard(rec, ctx);
        };
        rec.handle = handle;

        signal.wait();

        if (rec.spawn_failed) {
            if (rec.spawn_error) |failure| {
                rec.spawn_error = null;
                return self.discardFailure(rec, ctx, failure);
            }
            return self.discard(rec, ctx);
        }

        host.loop.ref();
        return .{ .ok = .{ .id = id, .pid = rec.pid } };
    }

    /// Releases stdin resources exactly once, after the writer is gone.
    fn releaseStdin(self: *ChildProcesses, rec: *Child) void {
        if (rec.stdin_file) |file| {
            rec.stdin_file = null;
            std.Io.File.close(file, self.io);
        }
        rec.stdin_queue.freeChunks(self.allocator);
    }

    /// Removes and frees a record that never produced a live process.
    fn discard(self: *ChildProcesses, rec: *Child, ctx: *quickjs.Context) std.mem.Allocator.Error {
        _ = self.map.remove(rec.id);
        rec.dispatch.deinit(ctx);
        self.releaseStdin(rec);
        rec.stdout_flow.deinit();
        rec.stderr_flow.deinit();
        self.allocator.destroy(rec);
        return error.OutOfMemory;
    }

    fn discardFailure(
        self: *ChildProcesses,
        rec: *Child,
        ctx: *quickjs.Context,
        failure: Failure,
    ) SpawnResult {
        _ = self.map.remove(rec.id);
        // The coordinator signals us and returns; join so the task can no
        // longer touch `rec` or `failure` while we free it.
        rec.handle.join();
        rec.dispatch.deinit(ctx);
        self.releaseStdin(rec);
        rec.stdout_flow.deinit();
        rec.stderr_flow.deinit();
        self.allocator.destroy(rec);
        return .{ .failure = failure };
    }

    /// POSIX signals the pid directly because the coordinator owns `wait`;
    /// reaping here would race it.
    pub fn kill(self: *ChildProcesses, id: u64, sig: std.posix.SIG) bool {
        const rec = self.map.get(id) orelse return false;

        if (builtin.os.tag == .windows) {
            if (rec.child.id == null) return false;
            rec.child.kill(self.io);
            return true;
        }

        if (rec.pid < 0 or rec.exited.load(.acquire)) return false;
        std.posix.kill(rec.pid, sig) catch return false;
        return true;
    }

    /// `kill(0)`-style liveness probe; mirrors Node's `process.kill(pid, 0)`.
    pub fn isAlive(self: *ChildProcesses, id: u64) bool {
        const rec = self.map.get(id) orelse return false;
        return !rec.exited.load(.acquire);
    }

    /// Toggles whether this child keeps the JS loop alive.
    pub fn setRef(self: *ChildProcesses, id: u64, ref: bool, loop: *EventLoop) bool {
        const rec = self.map.get(id) orelse return false;
        if (rec.refs == ref) return true;
        rec.refs = ref;
        if (ref) loop.ref() else loop.unref();
        return true;
    }

    /// Enqueues a stdin copy. Returns `0` accepted, `1` accepted over the
    /// limit (wait for `drain`), `2` closed. Never blocks the JS thread.
    pub fn writeStdin(self: *ChildProcesses, id: u64, bytes: []const u8) i32 {
        const rec = self.map.get(id) orelse return 2;
        const queue = &rec.stdin_queue;

        queue.mutex.lockUncancelable();
        defer queue.mutex.unlock();

        if (!queue.accepting) return 2;

        // Always enqueue: a `false` result means "wait for drain", not "lost".
        // Memory grows only when the caller ignores backpressure, as in Node.
        const copy = self.allocator.dupe(u8, bytes) catch {
            queue.accepting = false;
            queue.eof = true;
            queue.cond.broadcast();
            return 2;
        };
        queue.chunks.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            queue.accepting = false;
            queue.eof = true;
            queue.cond.broadcast();
            return 2;
        };
        queue.bytes += copy.len;
        queue.cond.signal();

        // A single write larger than the limit is accepted in full.
        if (queue.bytes > queue.limit) {
            queue.full = true;
            return 1;
        }
        return 0;
    }

    pub fn endStdin(self: *ChildProcesses, id: u64) bool {
        const rec = self.map.get(id) orelse return false;
        const queue = &rec.stdin_queue;

        queue.mutex.lockUncancelable();
        defer queue.mutex.unlock();

        if (!queue.accepting) return false;
        queue.accepting = false;
        queue.eof = true;
        queue.cond.broadcast();
        return true;
    }

    /// Native backpressure switch for `stdout`/`stderr`; unknown ids are false.
    pub fn setPaused(self: *ChildProcesses, id: u64, stream: u8, paused: bool) bool {
        const rec = self.map.get(id) orelse return false;
        const target = rec.flow(if (stream == 0) 0 else 1);
        if (paused) target.pause() else target.@"resume"();
        return true;
    }

    /// Kills every live child and waits for its coordinator, so no task can
    /// touch the queue or a record afterwards. Runs before `queue.shutdown`.
    pub fn deinit(self: *ChildProcesses, ctx: *quickjs.Context) void {
        var iterator = self.map.valueIterator();
        while (iterator.next()) |slot| {
            const rec = slot.*;
            self.terminate(rec);
            // Wake readers blocked on a credit before waiting for them.
            rec.stdout_flow.close();
            rec.stderr_flow.close();
            // Works without a task context: zio falls back to a futex wait.
            rec.handle.join();
            // Wake a writer stuck on the queue, then wait for it to close.
            rec.stdin_queue.close();
            if (rec.stdin_writer) |*writer| writer.join();
            self.releaseStdin(rec);
            rec.stdout_flow.deinit();
            rec.stderr_flow.deinit();
            rec.dispatch.deinit(ctx);
            self.allocator.destroy(rec);
        }
        self.map.deinit();
    }

    fn terminate(self: *ChildProcesses, rec: *Child) void {
        if (builtin.os.tag == .windows) {
            if (rec.child.id != null) rec.child.kill(self.io);
            return;
        }
        if (rec.pid < 0 or rec.exited.load(.acquire)) return;
        std.posix.kill(rec.pid, .KILL) catch {};
    }

    fn send(self: *ChildProcesses, id: u64, kind: Kind) bool {
        const job = self.allocator.create(ChildJob) catch {
            freeKind(self.allocator, kind);
            return false;
        };
        job.* = .{
            .link = .{
                .context = job,
                .settle = settleJob,
                .abort = abortJob,
            },
            .owner = self,
            .id = id,
            .kind = kind,
        };

        self.queue.submit(&job.link) catch {
            freeKind(self.allocator, job.kind);
            self.allocator.destroy(job);
            return false;
        };
        self.queue.complete(&job.link);
        return true;
    }

    fn sendData(self: *ChildProcesses, id: u64, stream: u8, bytes: []const u8) bool {
        const copy = self.allocator.dupe(u8, bytes) catch return false;
        return self.send(id, .{ .data = .{ .stream = stream, .bytes = copy } });
    }

    fn sendEnd(self: *ChildProcesses, id: u64, stream: u8) void {
        _ = self.send(id, .{ .end = stream });
    }

    fn sendExit(self: *ChildProcesses, id: u64, term: std.process.Child.Term) void {
        _ = self.send(id, .{ .exit = term });
    }

    fn sendStdinDrain(self: *ChildProcesses, id: u64) void {
        _ = self.send(id, .stdin_drain);
    }

    fn dispatchData(
        self: *ChildProcesses,
        ctx: *quickjs.Context,
        id: u64,
        stream: u8,
        bytes: []const u8,
    ) void {
        const rec = self.map.get(id) orelse return;
        defer rec.flow(stream).release();

        var payload = Value.initUint8ArrayCopy(ctx, bytes);
        if (payload.isException()) {
            clearException(ctx);
            payload = Value.null;
        }
        self.callDispatch(ctx, rec, "data", @intCast(stream), payload);
    }

    fn dispatchEnd(self: *ChildProcesses, ctx: *quickjs.Context, id: u64, stream: u8) void {
        const rec = self.map.get(id) orelse return;
        self.callDispatch(ctx, rec, "end", @intCast(stream), Value.null);
    }

    fn dispatchStdinDrain(self: *ChildProcesses, ctx: *quickjs.Context, id: u64) void {
        const rec = self.map.get(id) orelse return;
        self.callDispatch(ctx, rec, "drain", -1, Value.null);
    }

    fn dispatchSpawnError(
        self: *ChildProcesses,
        ctx: *quickjs.Context,
        id: u64,
        failure: Failure,
    ) void {
        const rec = self.map.get(id) orelse return;

        // Spawn failures normally reach JS synchronously; this is a safety net.
        var payload = buildFailure(ctx, failure, "");
        if (payload.isException()) {
            clearException(ctx);
            payload = Value.null;
        }
        self.callDispatch(ctx, rec, "error", -1, payload);
    }

    fn dispatchExit(
        self: *ChildProcesses,
        ctx: *quickjs.Context,
        id: u64,
        term: std.process.Child.Term,
    ) void {
        const rec = self.map.get(id) orelse return;

        var code: ?u8 = null;
        var signal: ?std.posix.SIG = null;
        switch (term) {
            .exited => |value| code = value,
            .signal => |sig| signal = sig,
            .stopped => |sig| signal = sig,
            .unknown => {},
        }

        var signal_buffer: [64]u8 = undefined;
        var payload = Value.initObject(ctx);
        if (payload.isException()) {
            clearException(ctx);
            payload = Value.null;
        } else {
            const code_value = if (code) |value| Value.initInt32(@intCast(value)) else Value.null;
            _ = setField(ctx, payload, "code", code_value);
            const signal_value = if (signal) |sig|
                Value.initStringLen(ctx, std.fmt.bufPrint(
                    &signal_buffer,
                    "SIG{s}",
                    .{@tagName(sig)},
                ) catch "SIG")
            else
                Value.null;
            _ = setField(ctx, payload, "signal", signal_value);
        }

        self.callDispatch(ctx, rec, "exit", -1, payload);

        if (ctx.getOpaque(Host)) |host| {
            if (rec.refs) host.loop.unref();
        }
        _ = self.map.remove(id);
        // The coordinator enqueued this job and is returning; join before
        // freeing the record it was using.
        rec.handle.join();
        self.releaseStdin(rec);
        rec.stdout_flow.deinit();
        rec.stderr_flow.deinit();
        rec.dispatch.deinit(ctx);
        self.allocator.destroy(rec);
    }

    /// Invokes the JS trampoline; it owns the payload from here.
    fn callDispatch(
        self: *ChildProcesses,
        ctx: *quickjs.Context,
        rec: *Child,
        event: [*:0]const u8,
        stream: i32,
        payload: Value,
    ) void {
        _ = self;
        const id_value = Value.initFloat64(@floatFromInt(rec.id));
        defer id_value.deinit(ctx);
        const event_value = Value.initString(ctx, event);
        defer event_value.deinit(ctx);
        const stream_value = Value.initInt32(stream);
        defer stream_value.deinit(ctx);
        defer payload.deinit(ctx);

        const result = rec.dispatch.call(
            ctx,
            .undefined,
            &.{ id_value, event_value, stream_value, payload },
        );
        defer result.deinit(ctx);
        // The wrapper rethrows listener errors asynchronously; drop the
        // exception instead of letting it escape the native frame.
        if (result.isException()) clearException(ctx);
    }
};

fn clearException(ctx: *quickjs.Context) void {
    const exception = ctx.getException();
    exception.deinit(ctx);
}

fn setField(ctx: *quickjs.Context, object: Value, name: [*:0]const u8, value: Value) bool {
    object.setPropertyStr(ctx, name, value) catch return false;
    return true;
}

fn buildFailure(ctx: *quickjs.Context, failure: Failure, command: []const u8) Value {
    const object = Value.initObject(ctx);
    if (object.isException()) return object;

    _ = setField(ctx, object, "code", Value.initString(ctx, failure.code));
    _ = setField(ctx, object, "message", Value.initStringLen(ctx, failure.message));
    _ = setField(ctx, object, "errno", Value.initInt32(failure.errno));
    _ = setField(ctx, object, "syscall", Value.initStringLen(ctx, failure.syscall));
    _ = setField(ctx, object, "path", Value.initStringLen(ctx, command));
    return object;
}

fn settleJob(ctx: *quickjs.Context, link: *jobs.Job) void {
    const job: *ChildJob = @ptrCast(@alignCast(link.context));
    const owner = job.owner;
    defer owner.allocator.destroy(job);

    switch (job.kind) {
        .data => |data| {
            defer owner.allocator.free(data.bytes);
            owner.dispatchData(ctx, job.id, data.stream, data.bytes);
        },
        .end => |stream| owner.dispatchEnd(ctx, job.id, stream),
        .exit => |term| owner.dispatchExit(ctx, job.id, term),
        .stdin_drain => owner.dispatchStdinDrain(ctx, job.id),
        .spawn_error => |failure| {
            defer owner.allocator.free(failure.message);
            defer owner.allocator.free(failure.syscall);
            owner.dispatchSpawnError(ctx, job.id, failure);
        },
    }
}

fn abortJob(_: *quickjs.Context, link: *jobs.Job) void {
    const job: *ChildJob = @ptrCast(@alignCast(link.context));
    const owner = job.owner;
    freeKind(owner.allocator, job.kind);
    owner.allocator.destroy(job);
}

/// Runs in a zio task: spawn, drain both pipes, then reap.
fn startChild(
    owner: *ChildProcesses,
    host: *Host,
    rec: *Child,
    argv: []const []const u8,
    options: *const Options,
    signal: *Signal,
) void {
    // `spawn` only borrows the environment map, so the local copy outlives it.
    var env_copy = options.env;
    const env_ptr: ?*const std.process.Environ.Map = if (env_copy) |*map| map else host.environ;
    rec.child = std.process.spawn(owner.io, .{
        .argv = argv,
        .cwd = if (options.cwd) |path| .{ .path = path } else .inherit,
        .environ_map = env_ptr,
        .stdin = options.stdin,
        .stdout = options.stdout,
        .stderr = options.stderr,
        .uid = if (options.uid) |value| @intCast(value) else null,
        .gid = if (options.gid) |value| @intCast(value) else null,
        .create_no_window = options.windows_hide,
        .pgid = if (options.detached) 0 else null,
    }) catch |spawn_err| {
        rec.spawn_failed = true;
        rec.spawn_error = launchFailure(owner.allocator, argv[0], spawn_err) catch null;
        signal.notify();
        return;
    };

    rec.pid = if (builtin.os.tag == .windows)
        -1
    else if (rec.child.id) |id| @intCast(id) else -1;
    // Own stdin so `Child.wait` cleanup can never close it under the writer.
    rec.stdin_file = rec.child.stdin;
    rec.child.stdin = null;
    if (rec.stdin_file != null) {
        rec.stdin_writer = owner.rt.spawn(stdinWriter, .{ owner, rec }) catch null;
        if (rec.stdin_writer == null) {
            std.Io.File.close(rec.stdin_file.?, owner.io);
            rec.stdin_file = null;
            rec.stdin_queue.accepting = false;
            rec.stdin_queue.eof = true;
        }
    } else {
        rec.stdin_queue.accepting = false;
        rec.stdin_queue.eof = true;
    }
    signal.notify();
    // The JS task frees `argv`/`options` once it wakes; nothing below may read
    // them.

    var readers: [2]?zio.JoinHandle(void) = .{ null, null };
    if (rec.child.stdout) |file| {
        readers[0] = owner.rt.spawn(readStream, .{ owner, rec.id, 0, file, &rec.stdout_flow }) catch null;
    }
    if (rec.child.stderr) |file| {
        readers[1] = owner.rt.spawn(readStream, .{ owner, rec.id, 1, file, &rec.stderr_flow }) catch null;
    }
    for (&readers) |*slot| {
        if (slot.*) |*handle| handle.join();
    }

    const term = rec.child.wait(owner.io) catch std.process.Child.Term{ .unknown = 0 };

    // Tell the writer to drain and stop, then wait for it to close the pipe.
    rec.stdin_queue.close();
    if (rec.stdin_writer) |*writer| writer.join();
    if (rec.stdin_file) |file| {
        rec.stdin_file = null;
        std.Io.File.close(file, owner.io);
    }
    rec.exited.store(true, .release);

    owner.sendExit(rec.id, term);
}

/// Runs in a zio task: drains the queue into `stdin_file`, then closes it.
fn stdinWriter(owner: *ChildProcesses, rec: *Child) void {
    const queue = &rec.stdin_queue;

    outer: while (true) {
        queue.mutex.lockUncancelable();

        while (queue.chunks.items.len == 0 and !queue.eof) {
            queue.cond.waitUncancelable(&queue.mutex);
        }
        if (queue.chunks.items.len == 0 and queue.eof) {
            queue.accepting = false;
            queue.mutex.unlock();
            break;
        }

        const chunk = queue.chunks.orderedRemove(0);
        queue.bytes -= chunk.len;

        var send_drain = false;
        if (queue.full and queue.bytes < queue.limit) {
            queue.full = false;
            send_drain = true;
        }
        queue.mutex.unlock();

        if (send_drain) owner.sendStdinDrain(rec.id);

        if (rec.stdin_file) |file| {
            std.Io.File.writeStreamingAll(file, owner.io, chunk) catch {
                owner.allocator.free(chunk);
                queue.close();
                break :outer;
            };
        }
        owner.allocator.free(chunk);
    }

    queue.close();

    if (rec.stdin_file) |file| {
        rec.stdin_file = null;
        std.Io.File.close(file, owner.io);
    }
    queue.freeChunks(owner.allocator);
}

fn readStream(
    owner: *ChildProcesses,
    id: u64,
    stream: u8,
    file: std.Io.File,
    flow: *StreamFlow,
) void {
    var io_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.readerStreaming(file, owner.io, &io_buffer);
    var chunk: [16 * 1024]u8 = undefined;

    while (true) {
        if (!flow.acquire()) break;
        const count = reader.interface.readSliceShort(&chunk) catch {
            flow.release();
            break;
        };
        if (count == 0) {
            flow.release();
            break;
        }
        // A successful send keeps its credit until the JS task dispatches it.
        if (!owner.sendData(id, stream, chunk[0..count])) flow.release();
    }
    owner.sendEnd(id, stream);
}
