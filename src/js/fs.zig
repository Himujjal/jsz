const std = @import("std");
const builtin = @import("builtin");
const quickjs = @import("quickjs");
const Host = @import("host.zig").Host;
const fs = @import("../fs.zig");

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

/// Copies file contents out of the JS heap before the worker task starts.
fn argData(
    host: *Host,
    ctx: *quickjs.Context,
    args: []const quickjs.c.JSValue,
    index: usize,
) ?[]u8 {
    const value = argValue(args, index);

    if (value.isString()) {
        const slice = value.toZigSlice(ctx) orelse {
            _ = ctx.throwInternalError("failed to read data argument");
            return null;
        };
        defer ctx.freeCString(slice.ptr);
        return host.allocator.dupe(u8, slice) catch {
            _ = ctx.throwOutOfMemory();
            return null;
        };
    }

    if (value.getUint8Array(ctx)) |bytes| {
        return host.allocator.dupe(u8, bytes) catch {
            _ = ctx.throwOutOfMemory();
            return null;
        };
    }

    _ = ctx.throwTypeError("The \"data\" argument must be a string, Buffer, or Uint8Array");
    return null;
}

fn argBool(
    ctx: *quickjs.Context,
    args: []const quickjs.c.JSValue,
    index: usize,
    default: bool,
) bool {
    const value = argValue(args, index);
    if (value.isUndefined() or value.isNull()) return default;
    return value.toBool(ctx) catch default;
}

fn argU32(ctx: *quickjs.Context, args: []const quickjs.c.JSValue, index: usize, default: u32) u32 {
    const value = argValue(args, index);
    if (value.isUndefined() or value.isNull()) return default;
    const number = value.toInt32(ctx) catch return default;
    if (number < 0) return default;
    return @intCast(number);
}

fn argU64(ctx: *quickjs.Context, args: []const quickjs.c.JSValue, index: usize, default: u64) u64 {
    const value = argValue(args, index);
    if (value.isUndefined() or value.isNull()) return default;
    const number = value.toFloat64(ctx) catch return default;
    if (std.math.isNan(number) or number < 0) return default;
    return @intFromFloat(number);
}

fn argF64(ctx: *quickjs.Context, args: []const quickjs.c.JSValue, index: usize, default: f64) f64 {
    const value = argValue(args, index);
    if (value.isUndefined() or value.isNull()) return default;
    return value.toFloat64(ctx) catch default;
}

/// JS numbers above `2^53` cannot be integers, so clamping there avoids
/// trapping `@intFromFloat` without losing a representable value.
fn floatToInt(comptime T: type, number: f64) ?T {
    if (!std.math.isFinite(number)) return null;
    if (number < -9007199254740992 or number > 9007199254740992) return null;
    return @intFromFloat(number);
}

fn argI64(ctx: *quickjs.Context, args: []const quickjs.c.JSValue, index: usize, default: i64) i64 {
    const value = argValue(args, index);
    if (!value.isNumber()) return default;
    const number = value.toFloat64(ctx) catch return default;
    return floatToInt(i64, number) orelse default;
}

/// Native surface already validated by `fs.js`; this only rejects flags the
/// syscall layer cannot express so a typo never silently picks a mode.
const OpenSpec = struct {
    readable: bool = false,
    writable: bool = false,
    create: bool = false,
    truncate: bool = false,
    exclusive: bool = false,
    append: bool = false,
};

const flag_table = [_]struct { name: [:0]const u8, spec: OpenSpec }{
    .{ .name = "r", .spec = .{ .readable = true } },
    .{ .name = "r+", .spec = .{ .readable = true, .writable = true } },
    .{ .name = "rs", .spec = .{ .readable = true } },
    .{ .name = "rs+", .spec = .{ .readable = true, .writable = true } },
    .{ .name = "w", .spec = .{ .writable = true, .create = true, .truncate = true } },
    .{ .name = "wx", .spec = .{ .writable = true, .create = true, .truncate = true, .exclusive = true } },
    .{ .name = "xw", .spec = .{ .writable = true, .create = true, .truncate = true, .exclusive = true } },
    .{ .name = "w+", .spec = .{ .readable = true, .writable = true, .create = true, .truncate = true } },
    .{ .name = "wx+", .spec = .{ .readable = true, .writable = true, .create = true, .truncate = true, .exclusive = true } },
    .{ .name = "xw+", .spec = .{ .readable = true, .writable = true, .create = true, .truncate = true, .exclusive = true } },
    .{ .name = "a", .spec = .{ .writable = true, .create = true, .append = true } },
    .{ .name = "ax", .spec = .{ .writable = true, .create = true, .append = true, .exclusive = true } },
    .{ .name = "xa", .spec = .{ .writable = true, .create = true, .append = true, .exclusive = true } },
    .{ .name = "a+", .spec = .{ .readable = true, .writable = true, .create = true, .append = true } },
    .{ .name = "ax+", .spec = .{ .readable = true, .writable = true, .create = true, .append = true, .exclusive = true } },
    .{ .name = "xa+", .spec = .{ .readable = true, .writable = true, .create = true, .append = true, .exclusive = true } },
    .{ .name = "as", .spec = .{ .writable = true, .create = true, .append = true } },
    .{ .name = "as+", .spec = .{ .readable = true, .writable = true, .create = true, .append = true } },
};

fn parseOpenSpec(flag: []const u8) ?OpenSpec {
    for (flag_table) |entry| {
        if (std.mem.eql(u8, flag, entry.name)) return entry.spec;
    }
    return null;
}

fn throwInvalidArgValue(
    ctx: *quickjs.Context,
    comptime fmt: []const u8,
    args: anytype,
) Value {
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrintSentinel(&buffer, fmt, args, 0) catch "Invalid argument";
    const error_value = ctx.newTypeError(message);
    error_value.setPropertyStr(ctx, "code", Value.initString(ctx, "ERR_INVALID_ARG_VALUE")) catch {};
    return error_value.throw(ctx);
}

fn argFd(ctx: *quickjs.Context, args: []const quickjs.c.JSValue, index: usize) ?std.Io.File.Handle {
    const value = argValue(args, index);
    if (!value.isNumber()) return null;
    const number = value.toFloat64(ctx) catch return null;
    if (builtin.os.tag == .windows) {
        if (number < 0) return null;
        const raw = floatToInt(usize, number) orelse return null;
        return switch (raw) {
            0 => std.Io.File.stdin().handle,
            1 => std.Io.File.stdout().handle,
            2 => std.Io.File.stderr().handle,
            else => @ptrFromInt(raw),
        };
    }
    const fd = floatToInt(i32, number) orelse return null;
    if (fd < 0) return null;
    return fd;
}

fn submitJob(host: *Host, ctx: *quickjs.Context, job: fs.Job) Value {
    const promise = Value.initPromiseCapability(ctx);

    const heap = host.allocator.create(fs.Job) catch {
        var temp = job;
        temp.freeFields(host.allocator);
        promise.deinit(ctx);
        return ctx.throwOutOfMemory();
    };

    heap.* = job;
    heap.resolve = promise.resolve;
    heap.reject = promise.reject;

    host.fs.submit(heap) catch {
        heap.resolve.deinit(ctx);
        heap.reject.deinit(ctx);
        heap.free(host.allocator);
        promise.value.deinit(ctx);
        return ctx.throwInternalError("failed to start fs operation");
    };

    return promise.value;
}

fn readFile(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const path = argString(host, ctx, args, 0, "path") orelse return .undefined;
    return submitJob(host, ctx, .{
        .op = .read_file,
        .path = path,
        .as_text = argBool(ctx, args, 1, false),
    });
}

fn writeFile(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    return write(ctx_opt, args, .write_file);
}

fn appendFile(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    return write(ctx_opt, args, .append_file);
}

fn write(
    ctx_opt: ?*quickjs.Context,
    args: []const quickjs.c.JSValue,
    op: fs.Op,
) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const path = argString(host, ctx, args, 0, "path") orelse return .undefined;
    const data = argData(host, ctx, args, 1) orelse {
        host.allocator.free(path);
        return .undefined;
    };

    return submitJob(host, ctx, .{
        .op = op,
        .path = path,
        .data = data,
        .data_owned = true,
        .exclusive = argBool(ctx, args, 2, false),
    });
}

fn stat(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const path = argString(host, ctx, args, 0, "path") orelse return .undefined;
    return submitJob(host, ctx, .{
        .op = .stat,
        .path = path,
        .follow = argBool(ctx, args, 1, true),
    });
}

fn readdir(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const path = argString(host, ctx, args, 0, "path") orelse return .undefined;
    return submitJob(host, ctx, .{ .op = .readdir, .path = path });
}

fn mkdir(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const path = argString(host, ctx, args, 0, "path") orelse return .undefined;
    return submitJob(host, ctx, .{
        .op = .mkdir,
        .path = path,
        .recursive = argBool(ctx, args, 1, false),
        .mode = argU32(ctx, args, 2, 0o777),
    });
}

fn remove(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const path = argString(host, ctx, args, 0, "path") orelse return .undefined;
    return submitJob(host, ctx, .{
        .op = .remove,
        .path = path,
        .recursive = argBool(ctx, args, 1, false),
        .force = argBool(ctx, args, 2, false),
        .dir_only = argBool(ctx, args, 3, false),
    });
}

fn rename(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const old_path = argString(host, ctx, args, 0, "oldPath") orelse return .undefined;
    const new_path = argString(host, ctx, args, 1, "newPath") orelse {
        host.allocator.free(old_path);
        return .undefined;
    };

    return submitJob(host, ctx, .{
        .op = .rename,
        .path = old_path,
        .path2 = new_path,
        .path2_owned = true,
    });
}

fn copyFile(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const src = argString(host, ctx, args, 0, "src") orelse return .undefined;
    const dest = argString(host, ctx, args, 1, "dest") orelse {
        host.allocator.free(src);
        return .undefined;
    };

    return submitJob(host, ctx, .{
        .op = .copy_file,
        .path = src,
        .path2 = dest,
        .path2_owned = true,
        .exclusive = argBool(ctx, args, 2, false),
    });
}

fn access(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const path = argString(host, ctx, args, 0, "path") orelse return .undefined;
    return submitJob(host, ctx, .{
        .op = .access,
        .path = path,
        .access_mode = @intCast(argU32(ctx, args, 1, 0) & 0x7),
    });
}

fn realpath(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const path = argString(host, ctx, args, 0, "path") orelse return .undefined;
    return submitJob(host, ctx, .{ .op = .realpath, .path = path });
}

fn readlink(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const path = argString(host, ctx, args, 0, "path") orelse return .undefined;
    return submitJob(host, ctx, .{ .op = .readlink, .path = path });
}

fn symlink(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const target = argString(host, ctx, args, 0, "target") orelse return .undefined;
    const link_path = argString(host, ctx, args, 1, "path") orelse {
        host.allocator.free(target);
        return .undefined;
    };

    return submitJob(host, ctx, .{
        .op = .symlink,
        .path = target,
        .path2 = link_path,
        .path2_owned = true,
    });
}

fn truncate(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const path = argString(host, ctx, args, 0, "path") orelse return .undefined;
    return submitJob(host, ctx, .{
        .op = .truncate,
        .path = path,
        .length = argU64(ctx, args, 1, 0),
    });
}

fn chmod(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const path = argString(host, ctx, args, 0, "path") orelse return .undefined;
    return submitJob(host, ctx, .{
        .op = .chmod,
        .path = path,
        .mode = argU32(ctx, args, 1, 0o666),
    });
}

fn chown(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const path = argString(host, ctx, args, 0, "path") orelse return .undefined;
    return submitJob(host, ctx, .{
        .op = .chown,
        .path = path,
        .uid = argU32(ctx, args, 1, 0),
        .gid = argU32(ctx, args, 2, 0),
    });
}

fn link(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const existing = argString(host, ctx, args, 0, "existingPath") orelse return .undefined;
    const new_path = argString(host, ctx, args, 1, "newPath") orelse {
        host.allocator.free(existing);
        return .undefined;
    };

    return submitJob(host, ctx, .{
        .op = .hard_link,
        .path = existing,
        .path2 = new_path,
        .path2_owned = true,
    });
}

fn utimes(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const path = argString(host, ctx, args, 0, "path") orelse return .undefined;
    return submitJob(host, ctx, .{
        .op = .utimes,
        .path = path,
        .atime_ms = argF64(ctx, args, 1, 0),
        .mtime_ms = argF64(ctx, args, 2, 0),
    });
}

fn mkdtemp(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const prefix = argString(host, ctx, args, 0, "prefix") orelse return .undefined;
    return submitJob(host, ctx, .{ .op = .mkdtemp, .path = prefix });
}

fn open(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const path = argString(host, ctx, args, 0, "path") orelse return .undefined;

    const value = argValue(args, 1);
    if (!value.isString()) {
        host.allocator.free(path);
        return ctx.throwTypeError("The \"flags\" argument must be of type string");
    }

    const slice = value.toZigSlice(ctx) orelse {
        host.allocator.free(path);
        return ctx.throwInternalError("failed to read flags argument");
    };
    defer ctx.freeCString(slice.ptr);

    const spec = parseOpenSpec(slice) orelse {
        host.allocator.free(path);
        return throwInvalidArgValue(ctx, "The value \"{s}\" is invalid for option \"flags\"", .{slice});
    };

    return submitJob(host, ctx, .{
        .op = .open,
        .path = path,
        .mode = argU32(ctx, args, 2, 0o666),
        .readable = spec.readable,
        .writable = spec.writable,
        .create = spec.create,
        .truncate_on_open = spec.truncate,
        .exclusive = spec.exclusive,
        .append = spec.append,
    });
}

fn close(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    return submitJob(host, ctx, .{ .op = .close, .fd = argFd(ctx, args, 0) });
}

fn read(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    return submitJob(host, ctx, .{
        .op = .read_fd,
        .fd = argFd(ctx, args, 0),
        .length = argU64(ctx, args, 1, 0),
        .position = argI64(ctx, args, 2, -1),
    });
}

fn writeFd(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const data = argData(host, ctx, args, 1) orelse return .undefined;
    return submitJob(host, ctx, .{
        .op = .write_fd,
        .fd = argFd(ctx, args, 0),
        .data = data,
        .data_owned = true,
        .position = argI64(ctx, args, 2, -1),
        .append = argBool(ctx, args, 3, false),
    });
}

fn fsync(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    return submitJob(host, ctx, .{ .op = .fsync, .fd = argFd(ctx, args, 0) });
}

fn fstat(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    return submitJob(host, ctx, .{ .op = .fstat, .fd = argFd(ctx, args, 0) });
}

fn ftruncate(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    return submitJob(host, ctx, .{
        .op = .ftruncate,
        .fd = argFd(ctx, args, 0),
        .length = argU64(ctx, args, 1, 0),
    });
}

const Export = struct {
    name: [:0]const u8,
    func: quickjs.cfunc.Func,
    nargs: i32,
};

const module_exports = [_]Export{
    .{ .name = "readFile", .func = readFile, .nargs = 2 },
    .{ .name = "writeFile", .func = writeFile, .nargs = 3 },
    .{ .name = "appendFile", .func = appendFile, .nargs = 3 },
    .{ .name = "stat", .func = stat, .nargs = 2 },
    .{ .name = "readdir", .func = readdir, .nargs = 1 },
    .{ .name = "mkdir", .func = mkdir, .nargs = 3 },
    .{ .name = "remove", .func = remove, .nargs = 4 },
    .{ .name = "rename", .func = rename, .nargs = 2 },
    .{ .name = "copyFile", .func = copyFile, .nargs = 3 },
    .{ .name = "access", .func = access, .nargs = 2 },
    .{ .name = "realpath", .func = realpath, .nargs = 1 },
    .{ .name = "readlink", .func = readlink, .nargs = 1 },
    .{ .name = "symlink", .func = symlink, .nargs = 2 },
    .{ .name = "truncate", .func = truncate, .nargs = 2 },
    .{ .name = "chmod", .func = chmod, .nargs = 2 },
    .{ .name = "chown", .func = chown, .nargs = 3 },
    .{ .name = "utimes", .func = utimes, .nargs = 3 },
    .{ .name = "link", .func = link, .nargs = 2 },
    .{ .name = "mkdtemp", .func = mkdtemp, .nargs = 1 },
    .{ .name = "open", .func = open, .nargs = 3 },
    .{ .name = "close", .func = close, .nargs = 1 },
    .{ .name = "read", .func = read, .nargs = 3 },
    .{ .name = "write", .func = writeFd, .nargs = 4 },
    .{ .name = "fsync", .func = fsync, .nargs = 1 },
    .{ .name = "fstat", .func = fstat, .nargs = 1 },
    .{ .name = "ftruncate", .func = ftruncate, .nargs = 2 },
};

fn moduleInit(ctx: *quickjs.Context, def: *quickjs.ModuleDef) bool {
    inline for (module_exports) |entry| {
        const function = Value.initCFunction(ctx, entry.func, entry.name, entry.nargs);
        if (!def.setExport(ctx, entry.name, function)) return false;
    }
    return true;
}

pub fn initModule(ctx: *quickjs.Context) ?*quickjs.ModuleDef {
    const def = quickjs.ModuleDef.init(ctx, "node:_fs", moduleInit) orelse return null;
    inline for (module_exports) |entry| {
        _ = def.addExport(ctx, entry.name);
    }
    return def;
}
