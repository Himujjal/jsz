const std = @import("std");
const builtin = @import("builtin");
const quickjs = @import("quickjs");
const zio = @import("zio");
const Host = @import("host.zig").Host;
const value_mod = @import("value.zig");

const Value = quickjs.Value;

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

/// `Environ.Map` asserts on invalid keys, so every key is validated first.
inline fn validKey(key: []const u8) bool {
    return key.len > 0 and std.mem.indexOfAny(u8, key, &.{ 0, '=' }) == null;
}

fn argv(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const values = host.allocator.alloc(Value, host.argv.len) catch return ctx.throwOutOfMemory();
    defer host.allocator.free(values);
    for (host.argv, 0..) |arg, index| values[index] = Value.initStringLen(ctx, arg);

    // JS_NewArrayFrom copies the values, so the array owns them from here on.
    return Value.initArrayFrom(ctx, values);
}

fn envGet(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const key = argString(host, ctx, args, 0, "key") orelse return .undefined;
    defer host.allocator.free(key);
    if (!validKey(key)) return .undefined;

    const value = host.environ.get(key) orelse return .undefined;
    return Value.initStringLen(ctx, value);
}

fn envSet(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const key = argString(host, ctx, args, 0, "key") orelse return .undefined;
    defer host.allocator.free(key);
    if (!validKey(key)) return .undefined;

    const value = argString(host, ctx, args, 1, "value") orelse return .undefined;
    defer host.allocator.free(value);

    _ = host.environ.put(key, value) catch return ctx.throwOutOfMemory();
    return .undefined;
}

fn envDelete(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const key = argString(host, ctx, args, 0, "key") orelse return .undefined;
    defer host.allocator.free(key);
    if (!validKey(key)) return .undefined;

    _ = host.environ.swapRemove(key);
    return .undefined;
}

fn envHas(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const key = argString(host, ctx, args, 0, "key") orelse return .undefined;
    defer host.allocator.free(key);
    if (!validKey(key)) return Value.initBool(false);

    return Value.initBool(host.environ.get(key) != null);
}

fn envKeys(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const keys = host.environ.keys();
    const values = host.allocator.alloc(Value, keys.len) catch return ctx.throwOutOfMemory();
    defer host.allocator.free(values);
    for (keys, 0..) |key, index| values[index] = Value.initStringLen(ctx, key);

    return Value.initArrayFrom(ctx, values);
}

fn cwd(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const path = std.process.currentPathAlloc(host.io, host.allocator) catch {
        return ctx.throwInternalError("failed to read the current working directory");
    };
    defer host.allocator.free(path);

    return Value.initStringLen(ctx, path);
}

fn chdir(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const path = argString(host, ctx, args, 0, "path") orelse return .undefined;
    defer host.allocator.free(path);

    std.process.setCurrentPath(host.io, path) catch |err| {
        return Value.initStringLen(ctx, chdirCode(err));
    };
    host.refreshCwd();
    return Value.initStringLen(ctx, "");
}

fn chdirCode(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "ENOENT",
        error.NotDir => "ENOTDIR",
        error.AccessDenied => "EACCES",
        error.NameTooLong => "ENAMETOOLONG",
        else => "EIO",
    };
}

fn exit(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const code = argValue(args, 0).toInt32(ctx) catch 0;
    host.loop.exit_code = @truncate(@as(u32, @bitCast(code)));
    host.loop.stop();
    return .undefined;
}

fn setExitCode(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const code = argValue(args, 0).toInt32(ctx) catch 0;
    host.loop.exit_code = @truncate(@as(u32, @bitCast(code)));
    return .undefined;
}

fn setHook(
    ctx: *quickjs.Context,
    args: []const quickjs.c.JSValue,
    comptime field: []const u8,
) Value {
    const host = hostOf(ctx) orelse return .undefined;
    const listener = argValue(args, 0);
    if (!listener.isFunction(ctx)) {
        _ = ctx.throwTypeError("The \"listener\" argument must be of type function");
        return .undefined;
    }

    const slot = &@field(host.loop.*, field);
    if (slot.*) |previous| previous.deinit(ctx);
    slot.* = listener.dup(ctx);
    if (comptime std.mem.eql(u8, field, "sigint_hook")) host.loop.sigint_wanted = true;
    return .undefined;
}

fn clearHook(ctx: *quickjs.Context, comptime field: []const u8) Value {
    const host = hostOf(ctx) orelse return .undefined;

    const slot = &@field(host.loop.*, field);
    if (slot.*) |hook| hook.deinit(ctx);
    slot.* = null;
    return .undefined;
}

fn setExitHook(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return setHook(ctx, args, "exit_hook");
}

fn clearExitHook(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return clearHook(ctx, "exit_hook");
}

fn setSigintHook(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return setHook(ctx, args, "sigint_hook");
}

fn clearSigintHook(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return clearHook(ctx, "sigint_hook");
}

fn setUncaughtHook(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return setHook(ctx, args, "uncaught_hook");
}

fn clearUncaughtHook(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return clearHook(ctx, "uncaught_hook");
}

fn pid(_: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    return Value.initInt32(std.c.getpid());
}

fn ppid(_: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    return Value.initInt32(std.c.getppid());
}

fn platformName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        .windows => "win32",
        .illumos => "sunos",
        .linux => if (builtin.abi.isAndroid()) "android" else "linux",
        .freebsd => "freebsd",
        .openbsd => "openbsd",
        .netbsd => "netbsd",
        else => @tagName(builtin.os.tag),
    };
}

fn archName() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        .x86 => "ia32",
        .arm => "arm",
        .riscv64 => "riscv64",
        .powerpc64, .powerpc64le => "ppc64",
        .s390x => "s390x",
        .loongarch64 => "loong64",
        else => @tagName(builtin.cpu.arch),
    };
}

fn platform(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return Value.initStringLen(ctx, platformName());
}

fn arch(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return Value.initStringLen(ctx, archName());
}

fn nodeVersion(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return Value.initStringLen(ctx, "v22.0.0-jsz");
}

fn jszVersion(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return Value.initStringLen(ctx, @import("../root.zig").version);
}

fn zigVersion(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return Value.initStringLen(ctx, builtin.zig_version_string);
}

fn quickjsVersion(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return Value.initStringLen(ctx, "quickjs-ng");
}

fn zioVersion(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return Value.initStringLen(ctx, "0.19.0");
}

fn elapsedNs(host: *Host) u64 {
    return zio.now().toNanoseconds() -| host.loop.started_ns;
}

fn elapsedNanoseconds(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    return Value.initFloat64(@floatFromInt(elapsedNs(host)));
}

fn uptime(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    return Value.initFloat64(@as(f64, @floatFromInt(elapsedNs(host))) / 1e9);
}

fn execPath(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    // `std.fs.selfExePathAlloc` does not exist in Zig 0.17; this is its
    // replacement and follows symlinks on POSIX.
    const path = std.process.executablePathAlloc(host.io, host.allocator) catch {
        if (host.argv.len > 0) return Value.initStringLen(ctx, host.argv[0]);
        return Value.initStringLen(ctx, "");
    };
    defer host.allocator.free(path);
    return Value.initStringLen(ctx, path);
}

/// macOS reports `ru_maxrss` in bytes and Linux in kilobytes.
fn residentSetBytes() f64 {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return 0;

    const usage = std.posix.getrusage(0);
    const raw: i64 = @intCast(usage.maxrss);
    if (raw <= 0) return 0;

    const bytes: i64 = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit => raw,
        else => raw *| 1024,
    };
    return @floatFromInt(bytes);
}

fn memoryUsage(_: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    return Value.initFloat64(residentSetBytes());
}

fn umask(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    if (builtin.os.tag == .windows) return Value.initInt32(0);

    const value = argValue(args, 0);
    if (value.isNumber()) {
        const mask = value.toInt32(ctx) catch 0;
        if (mask >= 0) {
            const previous = std.c.umask(@intCast(@as(u32, @bitCast(mask)) & 0o777));
            return Value.initInt32(@intCast(previous));
        }
    }

    // libc has no read-only accessor, so read with 0 and put the mask back.
    const current = std.c.umask(0);
    _ = std.c.umask(current);
    return Value.initInt32(@intCast(current));
}

/// `process.stdout.write` and `process.stderr.write` share `host.out` with
/// `console`; there is one buffer and one flush at the end of `runtime.run`.
fn writeStream(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const value = argValue(args, 0);
    if (value.isString()) {
        const slice = value.toZigSlice(ctx) orelse {
            _ = ctx.throwInternalError("failed to read the stream chunk");
            return .undefined;
        };
        defer ctx.freeCString(slice.ptr);
        host.out.appendSlice(host.allocator, slice) catch return ctx.throwOutOfMemory();
        return Value.initBool(true);
    }

    if (value.isArrayBuffer() or value.isDataView() or
        (value.isObject() and value.getTypedArrayType() != null))
    {
        const bytes = value_mod.toBytes(host, ctx, value, "chunk") orelse return .undefined;
        defer host.allocator.free(bytes);
        host.out.appendSlice(host.allocator, bytes) catch return ctx.throwOutOfMemory();
        return Value.initBool(true);
    }

    _ = ctx.throwTypeError(
        "The \"chunk\" argument must be of type string or an instance of Buffer or Uint8Array",
    );
    return .undefined;
}

fn utsField(ctx: *quickjs.Context, comptime field: []const u8, fallback: []const u8) Value {
    if (builtin.os.tag == .windows) return Value.initStringLen(ctx, fallback);
    const uts = std.posix.uname();
    return Value.initStringLen(ctx, std.mem.sliceTo(&@field(uts, field), 0));
}

fn osPlatform(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return Value.initStringLen(ctx, platformName());
}

fn osArch(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return Value.initStringLen(ctx, archName());
}

fn osType(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return utsField(ctx, "sysname", "Windows_NT");
}

fn osRelease(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return utsField(ctx, "release", "");
}

fn osVersion(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return utsField(ctx, "version", "");
}

fn osMachine(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return utsField(ctx, "machine", archName());
}

fn osHostname(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    if (builtin.os.tag == .windows) return Value.initStringLen(ctx, "");

    var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = std.posix.gethostname(&buffer) catch "";
    return Value.initStringLen(ctx, hostname);
}

fn osCpuCount(_: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const count = std.Thread.getCpuCount() catch 1;
    return Value.initInt32(@intCast(@min(count, @as(usize, std.math.maxInt(i32)))));
}

fn osUptime(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const nanoseconds = std.Io.Timestamp.now(host.io, .boot).toNanoseconds();
    if (nanoseconds <= 0) return Value.initFloat64(0);
    return Value.initFloat64(@as(f64, @floatFromInt(nanoseconds)) / 1e9);
}

extern "c" fn getloadavg(loadavg: [*]f64, nelem: c_int) c_int;

fn osLoadavg(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;

    var loads: [3]f64 = .{ 0, 0, 0 };
    if (builtin.os.tag != .windows) _ = getloadavg(&loads, 3);

    var values: [3]Value = undefined;
    for (loads, 0..) |load, index| values[index] = Value.initFloat64(load);
    return Value.initArrayFrom(ctx, &values);
}

fn osUid(_: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    if (builtin.os.tag == .windows) return Value.initInt32(0);
    return Value.initInt32(@intCast(std.c.getuid()));
}

fn osGid(_: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    if (builtin.os.tag == .windows) return Value.initInt32(0);
    return Value.initInt32(@intCast(std.c.getgid()));
}

fn osTotalmem(_: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const total = std.process.totalSystemMemory() catch 0;
    return Value.initFloat64(@floatFromInt(total));
}

const Export = struct {
    name: [:0]const u8,
    func: quickjs.cfunc.Func,
    nargs: i32,
};

const module_exports = [_]Export{
    .{ .name = "argv", .func = argv, .nargs = 0 },
    .{ .name = "envGet", .func = envGet, .nargs = 1 },
    .{ .name = "envSet", .func = envSet, .nargs = 2 },
    .{ .name = "envDelete", .func = envDelete, .nargs = 1 },
    .{ .name = "envHas", .func = envHas, .nargs = 1 },
    .{ .name = "envKeys", .func = envKeys, .nargs = 0 },
    .{ .name = "cwd", .func = cwd, .nargs = 0 },
    .{ .name = "chdir", .func = chdir, .nargs = 1 },
    .{ .name = "exit", .func = exit, .nargs = 1 },
    .{ .name = "setExitCode", .func = setExitCode, .nargs = 1 },
    .{ .name = "setExitHook", .func = setExitHook, .nargs = 1 },
    .{ .name = "clearExitHook", .func = clearExitHook, .nargs = 0 },
    .{ .name = "setSigintHook", .func = setSigintHook, .nargs = 1 },
    .{ .name = "clearSigintHook", .func = clearSigintHook, .nargs = 0 },
    .{ .name = "setUncaughtHook", .func = setUncaughtHook, .nargs = 1 },
    .{ .name = "clearUncaughtHook", .func = clearUncaughtHook, .nargs = 0 },
    .{ .name = "pid", .func = pid, .nargs = 0 },
    .{ .name = "ppid", .func = ppid, .nargs = 0 },
    .{ .name = "platform", .func = platform, .nargs = 0 },
    .{ .name = "arch", .func = arch, .nargs = 0 },
    .{ .name = "execPath", .func = execPath, .nargs = 0 },
    .{ .name = "memoryUsage", .func = memoryUsage, .nargs = 0 },
    .{ .name = "umask", .func = umask, .nargs = 1 },
    .{ .name = "writeOut", .func = writeStream, .nargs = 1 },
    .{ .name = "writeErr", .func = writeStream, .nargs = 1 },
    .{ .name = "osPlatform", .func = osPlatform, .nargs = 0 },
    .{ .name = "osArch", .func = osArch, .nargs = 0 },
    .{ .name = "osType", .func = osType, .nargs = 0 },
    .{ .name = "osRelease", .func = osRelease, .nargs = 0 },
    .{ .name = "osVersion", .func = osVersion, .nargs = 0 },
    .{ .name = "osMachine", .func = osMachine, .nargs = 0 },
    .{ .name = "osHostname", .func = osHostname, .nargs = 0 },
    .{ .name = "osCpuCount", .func = osCpuCount, .nargs = 0 },
    .{ .name = "osUptime", .func = osUptime, .nargs = 0 },
    .{ .name = "osLoadavg", .func = osLoadavg, .nargs = 0 },
    .{ .name = "osUid", .func = osUid, .nargs = 0 },
    .{ .name = "osGid", .func = osGid, .nargs = 0 },
    .{ .name = "osTotalmem", .func = osTotalmem, .nargs = 0 },
    .{ .name = "nodeVersion", .func = nodeVersion, .nargs = 0 },
    .{ .name = "jszVersion", .func = jszVersion, .nargs = 0 },
    .{ .name = "zigVersion", .func = zigVersion, .nargs = 0 },
    .{ .name = "quickjsVersion", .func = quickjsVersion, .nargs = 0 },
    .{ .name = "zioVersion", .func = zioVersion, .nargs = 0 },
    .{ .name = "elapsedNanoseconds", .func = elapsedNanoseconds, .nargs = 0 },
    .{ .name = "uptime", .func = uptime, .nargs = 0 },
};

fn moduleInit(ctx: *quickjs.Context, def: *quickjs.ModuleDef) bool {
    inline for (module_exports) |entry| {
        const function = Value.initCFunction(ctx, entry.func, entry.name, entry.nargs);
        if (!def.setExport(ctx, entry.name, function)) return false;
    }
    return true;
}

pub fn initModule(ctx: *quickjs.Context) ?*quickjs.ModuleDef {
    const def = quickjs.ModuleDef.init(ctx, "node:_process", moduleInit) orelse return null;
    inline for (module_exports) |entry| {
        _ = def.addExport(ctx, entry.name);
    }
    return def;
}
