// Native access to the assets embedded by `jszc`. The `node:sea` facade adds
// decoding and the Node-compatible error shapes.

const std = @import("std");
const quickjs = @import("quickjs");
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

fn throwCode(
    ctx: *quickjs.Context,
    code: []const u8,
    message: []const u8,
) Value {
    const err = Value.initError(ctx);
    if (err.isException()) return err;
    err.setPropertyStr(ctx, "code", Value.initStringLen(ctx, code)) catch {};
    err.setPropertyStr(ctx, "message", Value.initStringLen(ctx, message)) catch {};
    return err.throw(ctx);
}

fn notSea(ctx: *quickjs.Context) Value {
    return throwCode(
        ctx,
        "ERR_NOT_IN_SINGLE_EXECUTABLE_APPLICATION",
        "The application is not running from a single executable",
    );
}

fn isSea(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    return Value.initBool(host.is_sea);
}

fn getAssetKeys(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    if (!host.is_sea) return notSea(ctx);

    const array = Value.initArray(ctx);
    for (host.assets, 0..) |asset, index| {
        array.setPropertyUint32(ctx, @intCast(index), Value.initStringLen(ctx, asset.key)) catch {
            array.deinit(ctx);
            return .undefined;
        };
    }
    return array;
}

fn getAsset(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    if (!host.is_sea) return notSea(ctx);

    const value = argValue(args, 0);
    if (!value.isString()) {
        return ctx.throwTypeError("The \"key\" argument must be of type string");
    }
    const slice = value.toZigSlice(ctx) orelse {
        _ = ctx.throwInternalError("failed to read the asset key");
        return .undefined;
    };
    defer ctx.freeCString(slice.ptr);

    const key = slice;
    const cleaned = @import("../sea.zig").cleanKey(key) orelse key;
    for (host.assets) |asset| {
        if (std.mem.eql(u8, asset.key, cleaned)) {
            return Value.initArrayBufferCopy(ctx, asset.data);
        }
    }

    const message = std.fmt.allocPrintSentinel(
        host.allocator,
        "No asset with key \"{s}\"",
        .{key},
        0,
    ) catch {
        _ = ctx.throwOutOfMemory();
        return .undefined;
    };
    defer host.allocator.free(message);
    return throwCode(
        ctx,
        "ERR_SINGLE_EXECUTABLE_APPLICATION_ASSET_NOT_FOUND",
        message,
    );
}

const Export = struct {
    name: [:0]const u8,
    func: quickjs.cfunc.Func,
    nargs: i32,
};

const module_exports = [_]Export{
    .{ .name = "isSea", .func = isSea, .nargs = 0 },
    .{ .name = "getAssetKeys", .func = getAssetKeys, .nargs = 0 },
    .{ .name = "getAsset", .func = getAsset, .nargs = 1 },
};

fn moduleInit(ctx: *quickjs.Context, def: *quickjs.ModuleDef) bool {
    inline for (module_exports) |entry| {
        const function = Value.initCFunction(ctx, entry.func, entry.name, entry.nargs);
        if (!def.setExport(ctx, entry.name, function)) return false;
    }
    return true;
}

pub fn initModule(ctx: *quickjs.Context) ?*quickjs.ModuleDef {
    const def = quickjs.ModuleDef.init(ctx, "node:_sea", moduleInit) orelse return null;
    inline for (module_exports) |entry| {
        _ = def.addExport(ctx, entry.name);
    }
    return def;
}
