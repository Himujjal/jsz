const std = @import("std");
const builtin = @import("builtin");
const quickjs = @import("quickjs");
const zio = @import("zio");
const Host = @import("host.zig").Host;
const core = @import("../child_process.zig");

const Value = quickjs.Value;
const Options = core.Options;
const Failure = core.Failure;
const StdIo = std.process.SpawnOptions.StdIo;
const default_max_buffer = core.default_max_buffer;

fn hostOf(ctx: *quickjs.Context) ?*Host {
    return ctx.getOpaque(Host) orelse {
        _ = ctx.throwInternalError("jsz host is not initialized");
        return null;
    };
}

fn argValue(args: []const quickjs.c.JSValue, index: usize) Value {
    if (index >= args.len) return .undefined;
    return Value.fromCVal(args[index]);
}

fn argString(
    host: *Host,
    ctx: *quickjs.Context,
    args: []const quickjs.c.JSValue,
    index: usize,
    name: [:0]const u8,
) ?[]u8 {
    const value = argValue(args, index);
    if (!value.isString()) {
        const message = std.fmt.allocPrintSentinel(host.allocator, "The \"{s}\" argument must be of type string", .{name}, 0) catch {
            _ = ctx.throwOutOfMemory();
            return null;
        };
        defer host.allocator.free(message);
        _ = ctx.throwTypeError(message);
        return null;
    }

    const slice = value.toZigSlice(ctx) orelse {
        _ = ctx.throwInternalError("failed to read string argument");
        return null;
    };
    defer ctx.freeCString(slice.ptr);

    return host.allocator.dupe(u8, slice) catch {
        _ = ctx.throwOutOfMemory();
        return null;
    };
}

const Outcome = struct {
    pid: ?i32 = null,
    status: ?u8 = null,
    signal: ?std.posix.SIG = null,
    stdout: ?[]u8 = null,
    stderr: ?[]u8 = null,
    failure: ?Failure = null,

    fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        if (self.stdout) |bytes| allocator.free(bytes);
        if (self.stderr) |bytes| allocator.free(bytes);
        if (self.failure) |*failure| failure.deinit(allocator);
    }
};

/// `spawnSync`-level failure: either the output limit or a pipe/wait error.
fn syncFailure(
    allocator: std.mem.Allocator,
    command: []const u8,
    code: [:0]const u8,
    errno: i32,
) std.mem.Allocator.Error!Failure {
    const message = try std.fmt.allocPrint(allocator, "spawnSync {s} {s}", .{ command, code });
    errdefer allocator.free(message);
    const syscall = try allocator.dupe(u8, "spawnSync");
    return .{
        .code = code,
        .errno = errno,
        .message = message,
        .syscall = syscall,
    };
}

fn parseStdio(ctx: *quickjs.Context, stdio: Value, index: u32) StdIo {
    const value = stdio.getPropertyUint32(ctx, index);
    defer value.deinit(ctx);
    if (!value.isString()) return .pipe;

    const slice = value.toZigSlice(ctx) orelse return .pipe;
    defer ctx.freeCString(slice.ptr);

    if (std.mem.eql(u8, slice, "ignore")) return .ignore;
    if (std.mem.eql(u8, slice, "inherit")) return .inherit;
    return .pipe;
}

fn timeoutErrno() i32 {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit => -60,
        else => -110,
    };
}

/// Shared with the sync watchdog task; `done` is set before `executeChild`
/// returns so the task never touches a dead stack frame.
const TimeoutState = struct {
    done: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),
    pid: i32,
    ms: u64,
    sig: std.posix.SIG,
};

fn watchdog(state: *TimeoutState) void {
    zio.sleep(.fromMilliseconds(state.ms)) catch return;
    if (state.done.load(.acquire)) return;
    state.timed_out.store(true, .release);
    std.posix.kill(state.pid, state.sig) catch {};
}

/// Turns a watchdog hit into Node's `ETIMEDOUT` spawnSync result while keeping
/// whatever output the child produced first.
fn applyTimeout(
    outcome: *Outcome,
    allocator: std.mem.Allocator,
    command: []const u8,
    options: *const Options,
    state: *const TimeoutState,
) std.mem.Allocator.Error!void {
    if (!state.timed_out.load(.acquire)) return;
    outcome.failure = try syncFailure(allocator, command, "ETIMEDOUT", timeoutErrno());
    outcome.status = null;
    outcome.signal = options.kill_signal;
}

/// Parses a `killSignal` value; a number of 0 means "no signal".
fn valueSignal(ctx: *quickjs.Context, value: Value) ?std.posix.SIG {
    if (value.isNumber()) {
        const number = value.toFloat64(ctx) catch return null;
        if (!std.math.isFinite(number) or number <= 0 or number > 64) return null;
        if (@floor(number) != number) return null;
        const tag: u8 = @intFromFloat(number);
        return std.enums.fromInt(std.posix.SIG, tag);
    }
    if (value.isString()) {
        const slice = value.toZigSlice(ctx) orelse return null;
        defer ctx.freeCString(slice.ptr);
        return parseSignal(slice);
    }
    return null;
}

fn valueId(ctx: *quickjs.Context, value: Value) ?u32 {
    if (!value.isNumber()) return null;
    const number = value.toFloat64(ctx) catch return null;
    if (!std.math.isFinite(number) or number < 0) return null;
    if (number > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return null;
    if (@floor(number) != number) return null;
    return @intFromFloat(number);
}

fn parseOptions(host: *Host, ctx: *quickjs.Context, value: Value) ?Options {
    var options: Options = .{};
    var committed = false;
    defer if (!committed) options.deinit(host.allocator);

    if (!value.isObject()) {
        committed = true;
        return options;
    }

    const cwd_value = value.getPropertyStr(ctx, "cwd");
    defer cwd_value.deinit(ctx);
    if (cwd_value.isString()) {
        const slice = cwd_value.toZigSlice(ctx) orelse {
            _ = ctx.throwInternalError("failed to read \"cwd\"");
            return null;
        };
        defer ctx.freeCString(slice.ptr);
        options.cwd = host.allocator.dupe(u8, slice) catch {
            _ = ctx.throwOutOfMemory();
            return null;
        };
    }

    const env_value = value.getPropertyStr(ctx, "envPairs");
    defer env_value.deinit(ctx);
    if (env_value.isArray()) {
        options.env = std.process.Environ.Map.init(host.allocator);
        const map = &options.env.?;
        const length = env_value.getLength(ctx) catch 0;
        var index: usize = 0;
        const count: usize = if (length > 0) @intCast(length) else 0;
        while (index < count) : (index += 1) {
            const pair = env_value.getPropertyUint32(ctx, @intCast(index));
            defer pair.deinit(ctx);

            const key_value = pair.getPropertyUint32(ctx, 0);
            defer key_value.deinit(ctx);
            const val_value = pair.getPropertyUint32(ctx, 1);
            defer val_value.deinit(ctx);
            if (!key_value.isString() or !val_value.isString()) continue;

            const key = key_value.toZigSlice(ctx) orelse continue;
            defer ctx.freeCString(key.ptr);
            const val = val_value.toZigSlice(ctx) orelse continue;
            defer ctx.freeCString(val.ptr);

            if (!std.process.Environ.Map.validateKeyForPut(key)) continue;
            map.put(key, val) catch {
                _ = ctx.throwOutOfMemory();
                return null;
            };
        }
    }

    const stdio_value = value.getPropertyStr(ctx, "stdio");
    defer stdio_value.deinit(ctx);
    if (stdio_value.isArray()) {
        options.stdin = parseStdio(ctx, stdio_value, 0);
        options.stdout = parseStdio(ctx, stdio_value, 1);
        options.stderr = parseStdio(ctx, stdio_value, 2);
    }

    const input_value = value.getPropertyStr(ctx, "input");
    defer input_value.deinit(ctx);
    if (input_value.getUint8Array(ctx)) |bytes| {
        options.input = host.allocator.dupe(u8, bytes) catch {
            _ = ctx.throwOutOfMemory();
            return null;
        };
    }

    const max_value = value.getPropertyStr(ctx, "maxBuffer");
    defer max_value.deinit(ctx);
    if (max_value.isNumber()) {
        const number = max_value.toFloat64(ctx) catch 0;
        if (std.math.isFinite(number) and number >= 1) {
            const clamped = @min(number, 9007199254740992.0);
            options.max_buffer = @intFromFloat(clamped);
        }
    }

    const timeout_value = value.getPropertyStr(ctx, "timeout");
    defer timeout_value.deinit(ctx);
    if (timeout_value.isNumber()) {
        const number = timeout_value.toFloat64(ctx) catch 0;
        if (std.math.isFinite(number) and number >= 0) {
            options.timeout_ms = @intFromFloat(@min(@floor(number), 9007199254740992.0));
        }
    }

    const signal_value = value.getPropertyStr(ctx, "killSignal");
    defer signal_value.deinit(ctx);
    if (valueSignal(ctx, signal_value)) |sig| options.kill_signal = sig;

    const uid_value = value.getPropertyStr(ctx, "uid");
    defer uid_value.deinit(ctx);
    options.uid = valueId(ctx, uid_value);

    const gid_value = value.getPropertyStr(ctx, "gid");
    defer gid_value.deinit(ctx);
    options.gid = valueId(ctx, gid_value);

    const hide_value = value.getPropertyStr(ctx, "windowsHide");
    defer hide_value.deinit(ctx);
    if (hide_value.isBool()) options.windows_hide = hide_value.toBool(ctx) catch false;

    const detached_value = value.getPropertyStr(ctx, "detached");
    defer detached_value.deinit(ctx);
    if (detached_value.isBool()) options.detached = detached_value.toBool(ctx) catch false;

    committed = true;
    return options;
}

fn appendArgs(
    host: *Host,
    ctx: *quickjs.Context,
    value: Value,
    argv: *std.ArrayList([]const u8),
) bool {
    if (value.isUndefined() or value.isNull()) return true;
    if (!value.isArray()) {
        _ = ctx.throwTypeError("The \"args\" argument must be an array of strings");
        return false;
    }

    const length = value.getLength(ctx) catch {
        _ = ctx.throwTypeError("The \"args\" argument must be an array of strings");
        return false;
    };
    const count: usize = if (length > 0) @intCast(length) else 0;

    var index: usize = 0;
    while (index < count) : (index += 1) {
        const item = value.getPropertyUint32(ctx, @intCast(index));
        defer item.deinit(ctx);
        if (!item.isString()) {
            _ = ctx.throwTypeError("The \"args\" argument must be an array of strings");
            return false;
        }

        const slice = item.toZigSlice(ctx) orelse {
            _ = ctx.throwInternalError("failed to read argument string");
            return false;
        };
        defer ctx.freeCString(slice.ptr);

        const owned = host.allocator.dupe(u8, slice) catch {
            _ = ctx.throwOutOfMemory();
            return false;
        };
        argv.append(host.allocator, owned) catch {
            host.allocator.free(owned);
            _ = ctx.throwOutOfMemory();
            return false;
        };
    }
    return true;
}

fn applyTerm(outcome: *Outcome, term: std.process.Child.Term) void {
    switch (term) {
        .exited => |code| outcome.status = code,
        .signal => |sig| outcome.signal = sig,
        .stopped => |sig| outcome.signal = sig,
        .unknown => {},
    }
}

fn readPipe(host: *Host, file: std.Io.File, limit: usize) ![]u8 {
    var buffer: [4096]u8 = undefined;
    var reader = std.Io.File.readerStreaming(file, host.io, &buffer);
    return reader.interface.allocRemaining(host.allocator, .limited(limit));
}

fn executeChild(
    host: *Host,
    command: []const u8,
    argv: []const []const u8,
    options: *const Options,
) std.mem.Allocator.Error!Outcome {
    const allocator = host.allocator;
    var outcome: Outcome = .{};
    errdefer outcome.deinit(allocator);

    // `spawn` only borrows the environment map, so the local copy outlives it.
    var env_copy = options.env;
    const env_ptr: ?*const std.process.Environ.Map = if (env_copy) |*map| map else host.environ;
    var child = std.process.spawn(host.io, .{
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
        outcome.failure = try core.launchFailure(allocator, command, spawn_err);
        return outcome;
    };
    defer child.kill(host.io);

    outcome.pid = if (builtin.os.tag == .windows)
        null
    else if (child.id) |id| @intCast(id) else null;

    var timeout_state = TimeoutState{
        .pid = outcome.pid orelse -1,
        .ms = options.timeout_ms,
        .sig = options.kill_signal,
    };
    var timeout_handle: ?zio.JoinHandle(void) = null;
    if (builtin.os.tag != .windows and options.timeout_ms > 0 and timeout_state.pid > 0) {
        timeout_handle = host.rt.spawn(watchdog, .{&timeout_state}) catch null;
    }
    defer {
        timeout_state.done.store(true, .release);
        if (timeout_handle) |*handle| handle.cancel();
    }

    // A piped stdin needs the payload and an EOF before the child can finish.
    if (child.stdin) |stdin_file| {
        if (options.input) |bytes| {
            if (bytes.len > 0) std.Io.File.writeStreamingAll(stdin_file, host.io, bytes) catch {};
        }
        std.Io.File.close(stdin_file, host.io);
        child.stdin = null;
    }

    if (child.stdout != null and child.stderr != null) {
        var streams: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi: std.Io.File.MultiReader = undefined;
        const files = [_]std.Io.File{ child.stdout.?, child.stderr.? };
        multi.init(allocator, host.io, streams.toStreams(), &files);
        defer multi.deinit();

        while (multi.fill(64, .none)) |_| {
            if (multi.reader(0).bufferedLen() > options.max_buffer or
                multi.reader(1).bufferedLen() > options.max_buffer)
            {
                outcome.failure = try syncFailure(allocator, command, "ENOBUFS", core.nobufsErrno());
                return outcome;
            }
        } else |fill_err| switch (fill_err) {
            error.EndOfStream => {},
            else => {
                outcome.failure = try syncFailure(allocator, command, "EIO", -5);
                return outcome;
            },
        }

        multi.checkAnyError() catch {
            outcome.failure = try syncFailure(allocator, command, "EIO", -5);
            return outcome;
        };

        const term = child.wait(host.io) catch {
            outcome.failure = try syncFailure(allocator, command, "EIO", -5);
            return outcome;
        };

        outcome.stdout = try multi.toOwnedSlice(0);
        outcome.stderr = try multi.toOwnedSlice(1);
        applyTerm(&outcome, term);
        try applyTimeout(&outcome, allocator, command, options, &timeout_state);
        return outcome;
    }

    if (child.stdout) |stdout_file| {
        outcome.stdout = readPipe(host, stdout_file, options.max_buffer) catch |read_err| {
            outcome.failure = try pipeFailure(allocator, command, read_err);
            return outcome;
        };
    } else if (child.stderr) |stderr_file| {
        outcome.stderr = readPipe(host, stderr_file, options.max_buffer) catch |read_err| {
            outcome.failure = try pipeFailure(allocator, command, read_err);
            return outcome;
        };
    }

    const term = child.wait(host.io) catch {
        outcome.failure = try syncFailure(allocator, command, "EIO", -5);
        return outcome;
    };
    applyTerm(&outcome, term);
    try applyTimeout(&outcome, allocator, command, options, &timeout_state);
    return outcome;
}

fn pipeFailure(
    allocator: std.mem.Allocator,
    command: []const u8,
    err: anyerror,
) std.mem.Allocator.Error!Failure {
    if (err == error.StreamTooLong) {
        return syncFailure(allocator, command, "ENOBUFS", core.nobufsErrno());
    }
    return syncFailure(allocator, command, "EIO", -5);
}

/// Hand-off between the JS task (which blocks) and the zio task that drives
/// the child. Pipe reads need a zio task; QuickJS is never touched there.
const Bridge = struct {
    mutex: zio.os.Mutex = .init(),
    cond: zio.os.Condition = .init(),
    done: bool = false,
    out_of_memory: bool = false,
    outcome: Outcome = .{},

    fn deinit(self: *Bridge) void {
        self.mutex.deinit();
        self.cond.deinit();
    }
};

fn runChildJob(
    bridge: *Bridge,
    host: *Host,
    command: []const u8,
    argv: []const []const u8,
    options: *const Options,
) void {
    bridge.outcome = executeChild(host, command, argv, options) catch blk: {
        bridge.out_of_memory = true;
        break :blk Outcome{};
    };

    bridge.mutex.lock();
    bridge.done = true;
    bridge.cond.signal();
    bridge.mutex.unlock();
}

fn runBlocking(
    host: *Host,
    command: []const u8,
    argv: []const []const u8,
    options: *const Options,
) !Outcome {
    var bridge: Bridge = .{};
    defer bridge.deinit();

    // Fire and forget: `fs.submit` ignores the same handle, and the wait below
    // guarantees the task is finished before `bridge` goes out of scope.
    _ = host.rt.spawn(runChildJob, .{ &bridge, host, command, argv, options }) catch
        return error.ChildTaskFailed;

    bridge.mutex.lock();
    while (!bridge.done) bridge.cond.wait(&bridge.mutex);
    bridge.mutex.unlock();

    if (bridge.out_of_memory) return error.OutOfMemory;
    return bridge.outcome;
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

fn buildResult(
    ctx: *quickjs.Context,
    outcome: *const Outcome,
    command: []const u8,
    signal_text: ?[]const u8,
) Value {
    const object = Value.initObject(ctx);
    if (object.isException()) return object;

    const pid = if (outcome.pid) |value| Value.initInt32(value) else Value.null;
    if (!setField(ctx, object, "pid", pid)) return abortObject(ctx, object);

    const status = if (outcome.status) |value| Value.initInt32(@intCast(value)) else Value.null;
    if (!setField(ctx, object, "status", status)) return abortObject(ctx, object);

    const signal = if (signal_text) |text| Value.initStringLen(ctx, text) else Value.null;
    if (!setField(ctx, object, "signal", signal)) return abortObject(ctx, object);

    const stdout = if (outcome.stdout) |bytes| Value.initUint8ArrayCopy(ctx, bytes) else Value.null;
    if (stdout.isException()) return abortObject(ctx, object);
    if (!setField(ctx, object, "stdout", stdout)) return abortObject(ctx, object);

    const stderr = if (outcome.stderr) |bytes| Value.initUint8ArrayCopy(ctx, bytes) else Value.null;
    if (stderr.isException()) return abortObject(ctx, object);
    if (!setField(ctx, object, "stderr", stderr)) return abortObject(ctx, object);

    const error_object = if (outcome.failure) |failure| buildFailure(ctx, failure, command) else Value.null;
    if (error_object.isException()) return abortObject(ctx, object);
    if (!setField(ctx, object, "error", error_object)) return abortObject(ctx, object);

    return object;
}

fn abortObject(ctx: *quickjs.Context, object: Value) Value {
    object.deinit(ctx);
    return .undefined;
}

fn argId(ctx: *quickjs.Context, args: []const quickjs.c.JSValue, index: usize) ?u64 {
    const value = argValue(args, index);
    if (!value.isNumber()) return null;
    const number = value.toFloat64(ctx) catch return null;
    if (!std.math.isFinite(number) or number < 0) return null;
    return @intFromFloat(number);
}

fn parseSignal(name: []const u8) ?std.posix.SIG {
    const bare = if (std.mem.startsWith(u8, name, "SIG")) name["SIG".len..] else name;
    return std.meta.stringToEnum(std.posix.SIG, bare);
}

/// `spawn(command, args, options, dispatch)`; returns `{ id, pid }` or `{ error }`.
fn spawn(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const command = argString(host, ctx, args, 0, "file") orelse return .undefined;
    defer host.allocator.free(command);

    var argv: std.ArrayList([]const u8) = .empty;
    defer {
        for (argv.items) |item| host.allocator.free(item);
        argv.deinit(host.allocator);
    }

    const command_copy = host.allocator.dupe(u8, command) catch return ctx.throwOutOfMemory();
    argv.append(host.allocator, command_copy) catch {
        host.allocator.free(command_copy);
        return ctx.throwOutOfMemory();
    };
    if (!appendArgs(host, ctx, argValue(args, 1), &argv)) return .undefined;

    var options = parseOptions(host, ctx, argValue(args, 2)) orelse return .undefined;
    defer options.deinit(host.allocator);

    const dispatch = argValue(args, 3);
    if (!dispatch.isFunction(ctx)) {
        _ = ctx.throwTypeError("The \"dispatch\" argument must be of type function");
        return .undefined;
    }

    const result = host.children.spawn(ctx, host, argv.items, &options, dispatch) catch
        return ctx.throwOutOfMemory();

    const object = Value.initObject(ctx);
    if (object.isException()) return object;

    switch (result) {
        .ok => |ok| {
            if (!setField(ctx, object, "id", Value.initFloat64(@floatFromInt(ok.id)))) return abortObject(ctx, object);
            const pid = if (ok.pid >= 0) Value.initInt32(ok.pid) else Value.null;
            if (!setField(ctx, object, "pid", pid)) return abortObject(ctx, object);
        },
        .failure => |failure| {
            var owned = failure;
            defer owned.deinit(host.allocator);
            const payload = buildFailure(ctx, owned, command);
            if (payload.isException()) return abortObject(ctx, object);
            if (!setField(ctx, object, "error", payload)) return abortObject(ctx, object);
        },
    }
    return object;
}

fn kill(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const id = argId(ctx, args, 0) orelse return Value.initBool(false);
    const signal_value = argValue(args, 1);

    if (signal_value.isNumber()) {
        const number = signal_value.toFloat64(ctx) catch return Value.initBool(false);
        if (!std.math.isFinite(number) or number < 0 or number > 64) return Value.initBool(false);
        if (@floor(number) != number) return Value.initBool(false);
        const tag: u8 = @intFromFloat(number);
        if (tag == 0) return Value.initBool(host.children.isAlive(id));
        const sig = std.enums.fromInt(std.posix.SIG, tag) orelse return Value.initBool(false);
        return Value.initBool(host.children.kill(id, sig));
    }

    if (!signal_value.isString()) return Value.initBool(false);
    const slice = signal_value.toZigSlice(ctx) orelse return Value.initBool(false);
    defer ctx.freeCString(slice.ptr);

    const sig = parseSignal(slice) orelse return Value.initBool(false);
    return Value.initBool(host.children.kill(id, sig));
}

fn setRef(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const id = argId(ctx, args, 0) orelse return Value.initBool(false);
    const ref_value = argValue(args, 1);
    if (!ref_value.isBool()) return Value.initBool(false);
    const ref = ref_value.toBool(ctx) catch return Value.initBool(false);
    return Value.initBool(host.children.setRef(id, ref, host.loop));
}

fn writeStdin(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const id = argId(ctx, args, 0) orelse return Value.initInt32(2);
    const bytes = argValue(args, 1).getUint8Array(ctx) orelse return Value.initInt32(2);
    return Value.initInt32(host.children.writeStdin(id, bytes));
}

fn endStdin(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const id = argId(ctx, args, 0) orelse return Value.initBool(false);
    return Value.initBool(host.children.endStdin(id));
}

fn setPaused(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const id = argId(ctx, args, 0) orelse return Value.initBool(false);
    const stream_value = argValue(args, 1);
    if (!stream_value.isNumber()) return Value.initBool(false);
    const stream_number = stream_value.toFloat64(ctx) catch return Value.initBool(false);
    const stream: u8 = if (stream_number == 0) 0 else 1;
    const paused_value = argValue(args, 2);
    if (!paused_value.isBool()) return Value.initBool(false);
    const paused = paused_value.toBool(ctx) catch return Value.initBool(false);
    return Value.initBool(host.children.setPaused(id, stream, paused));
}

fn spawnSync(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const command = argString(host, ctx, args, 0, "file") orelse return .undefined;
    defer host.allocator.free(command);

    var argv: std.ArrayList([]const u8) = .empty;
    defer {
        for (argv.items) |item| host.allocator.free(item);
        argv.deinit(host.allocator);
    }

    // `spawn` treats argv[0] as the executable, so it is always present.
    const command_copy = host.allocator.dupe(u8, command) catch return ctx.throwOutOfMemory();
    argv.append(host.allocator, command_copy) catch {
        host.allocator.free(command_copy);
        return ctx.throwOutOfMemory();
    };
    if (!appendArgs(host, ctx, argValue(args, 1), &argv)) return .undefined;

    var options = parseOptions(host, ctx, argValue(args, 2)) orelse return .undefined;
    defer options.deinit(host.allocator);

    var outcome = runBlocking(host, command, argv.items, &options) catch |err| switch (err) {
        error.OutOfMemory => return ctx.throwOutOfMemory(),
        else => return ctx.throwInternalError("failed to run the child process"),
    };
    defer outcome.deinit(host.allocator);

    var signal_buffer: [64]u8 = undefined;
    const signal_text: ?[]const u8 = if (outcome.signal) |sig|
        std.fmt.bufPrint(&signal_buffer, "SIG{s}", .{@tagName(sig)}) catch null
    else
        null;

    return buildResult(ctx, &outcome, command, signal_text);
}

const Export = struct {
    name: [:0]const u8,
    func: quickjs.cfunc.Func,
    nargs: i32,
};

const module_exports = [_]Export{
    .{ .name = "spawnSync", .func = spawnSync, .nargs = 3 },
    .{ .name = "spawn", .func = spawn, .nargs = 4 },
    .{ .name = "kill", .func = kill, .nargs = 2 },
    .{ .name = "writeStdin", .func = writeStdin, .nargs = 2 },
    .{ .name = "endStdin", .func = endStdin, .nargs = 1 },
    .{ .name = "setPaused", .func = setPaused, .nargs = 3 },
    .{ .name = "setRef", .func = setRef, .nargs = 2 },
};

fn moduleInit(ctx: *quickjs.Context, def: *quickjs.ModuleDef) bool {
    inline for (module_exports) |entry| {
        const function = Value.initCFunction(ctx, entry.func, entry.name, entry.nargs);
        if (!def.setExport(ctx, entry.name, function)) return false;
    }
    return true;
}

pub fn initModule(ctx: *quickjs.Context) ?*quickjs.ModuleDef {
    const def = quickjs.ModuleDef.init(ctx, "node:_child_process", moduleInit) orelse return null;
    inline for (module_exports) |entry| {
        _ = def.addExport(ctx, entry.name);
    }
    return def;
}
