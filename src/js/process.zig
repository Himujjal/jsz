const std = @import("std");
const builtin = @import("builtin");
const quickjs = @import("quickjs");
const zio = @import("zio");
const Host = @import("host.zig").Host;

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

fn pid(_: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    return Value.initInt32(std.c.getpid());
}

fn ppid(_: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    return Value.initInt32(std.c.getppid());
}

fn platform(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return Value.initStringLen(ctx, switch (builtin.os.tag) {
        .macos => "darwin",
        .windows => "win32",
        .illumos => "sunos",
        .linux => if (builtin.abi.isAndroid()) "android" else "linux",
        .freebsd => "freebsd",
        .openbsd => "openbsd",
        .netbsd => "netbsd",
        else => @tagName(builtin.os.tag),
    });
}

fn arch(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    return Value.initStringLen(ctx, switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        .x86 => "ia32",
        .arm => "arm",
        .riscv64 => "riscv64",
        .powerpc64, .powerpc64le => "ppc64",
        .s390x => "s390x",
        .loongarch64 => "loong64",
        else => @tagName(builtin.cpu.arch),
    });
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
    .{ .name = "pid", .func = pid, .nargs = 0 },
    .{ .name = "ppid", .func = ppid, .nargs = 0 },
    .{ .name = "platform", .func = platform, .nargs = 0 },
    .{ .name = "arch", .func = arch, .nargs = 0 },
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
