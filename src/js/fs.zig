const std = @import("std");
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
        .path = link_path,
        .path2 = target,
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
