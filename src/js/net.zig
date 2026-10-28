// Native `node:_net` surface. Every entry point runs on the JS task; the
// asynchronous work lives in `src/net.zig` and reports back through the shared
// completion queue as `dispatch(id, event, payload)` calls.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("host.zig").Host;
const core = @import("../net.zig");

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

fn argId(ctx: *quickjs.Context, args: []const quickjs.c.JSValue, index: usize) ?u64 {
    const value = argValue(args, index);
    if (!value.isNumber()) return null;
    const number = value.toFloat64(ctx) catch return null;
    if (!std.math.isFinite(number) or number < 0) return null;
    if (number > 9007199254740992.0) return null;
    return @intFromFloat(number);
}

fn argPort(ctx: *quickjs.Context, args: []const quickjs.c.JSValue, index: usize) u16 {
    const value = argValue(args, index);
    if (!value.isNumber()) return 0;
    const number = value.toFloat64(ctx) catch return 0;
    if (!std.math.isFinite(number) or number <= 0) return 0;
    if (number >= 65535) return 65535;
    return @intFromFloat(@floor(number));
}

fn argBacklog(ctx: *quickjs.Context, args: []const quickjs.c.JSValue, index: usize) u31 {
    const value = argValue(args, index);
    if (!value.isNumber()) return default_backlog;
    const number = value.toFloat64(ctx) catch return default_backlog;
    if (!std.math.isFinite(number) or number <= 0) return default_backlog;
    if (number > 4096) return 4096;
    return @intFromFloat(@floor(number));
}

const default_backlog: u31 = 511;

fn setField(ctx: *quickjs.Context, object: Value, name: [*:0]const u8, value: Value) bool {
    object.setPropertyStr(ctx, name, value) catch return false;
    return true;
}

fn abortObject(ctx: *quickjs.Context, object: Value) Value {
    object.deinit(ctx);
    return .undefined;
}

fn setEndpoint(ctx: *quickjs.Context, object: Value, addr: core.AddrText) bool {
    if (!setField(ctx, object, "address", Value.initStringLen(ctx, addr.slice()))) return false;
    if (!setField(ctx, object, "family", Value.initStringLen(ctx, core.familyName(addr.family)))) return false;
    return setField(ctx, object, "port", Value.initInt32(@intCast(addr.port)));
}

fn buildError(ctx: *quickjs.Context, info: core.ErrorInfo) Value {
    const object = Value.initObject(ctx);
    if (object.isException()) return object;
    _ = setField(ctx, object, "code", Value.initString(ctx, info.code));
    _ = setField(ctx, object, "message", Value.initStringLen(ctx, info.message()));
    _ = setField(ctx, object, "errno", Value.initInt32(info.errno));
    _ = setField(ctx, object, "syscall", Value.initString(ctx, info.syscall));
    return object;
}

fn invalidDispatch(ctx: *quickjs.Context) Value {
    _ = ctx.throwTypeError("The \"dispatch\" argument must be of type function");
    return .undefined;
}

/// `listen(host, port, backlog, dispatch)` -> `{ id, address, family, port }`.
fn listen(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const host_name = argString(host, ctx, args, 0, "host") orelse return .undefined;
    defer host.allocator.free(host_name);

    const port = argPort(ctx, args, 1);
    const backlog = argBacklog(ctx, args, 2);

    const dispatch = argValue(args, 3);
    if (!dispatch.isFunction(ctx)) return invalidDispatch(ctx);

    const outcome = host.net.listen(ctx, host_name, port, backlog, dispatch) catch
        return ctx.throwOutOfMemory();

    const object = Value.initObject(ctx);
    if (object.isException()) return object;

    switch (outcome) {
        .ok => |ok| {
            if (!setField(ctx, object, "id", Value.initFloat64(@floatFromInt(ok.id)))) return abortObject(ctx, object);
            if (!setEndpoint(ctx, object, ok.addr)) return abortObject(ctx, object);
            host.loop.ref();
        },
        .failure => |failure| {
            const payload = buildError(ctx, failure);
            if (payload.isException()) return abortObject(ctx, object);
            if (!setField(ctx, object, "error", payload)) return abortObject(ctx, object);
        },
    }
    return object;
}

/// `connect(host, port, dispatch)` -> `{ id }` or `{ error }`.
fn connect(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const host_name = argString(host, ctx, args, 0, "host") orelse return .undefined;
    defer host.allocator.free(host_name);

    const port = argPort(ctx, args, 1);

    const dispatch = argValue(args, 2);
    if (!dispatch.isFunction(ctx)) return invalidDispatch(ctx);

    const outcome = host.net.connect(ctx, host_name, port, dispatch) catch
        return ctx.throwOutOfMemory();

    const object = Value.initObject(ctx);
    if (object.isException()) return object;

    switch (outcome) {
        .ok => |id| {
            if (!setField(ctx, object, "id", Value.initFloat64(@floatFromInt(id)))) return abortObject(ctx, object);
            host.loop.ref();
        },
        .failure => |failure| {
            const payload = buildError(ctx, failure);
            if (payload.isException()) return abortObject(ctx, object);
            if (!setField(ctx, object, "error", payload)) return abortObject(ctx, object);
        },
    }
    return object;
}

fn write(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const id = argId(ctx, args, 0) orelse return Value.initInt32(2);
    const value = argValue(args, 1);

    var owned: ?[]u8 = null;
    defer if (owned) |bytes| host.allocator.free(bytes);

    const bytes: []const u8 = if (value.getUint8Array(ctx)) |view|
        view
    else if (value.isString()) blk: {
        const slice = value.toZigSlice(ctx) orelse return Value.initInt32(2);
        defer ctx.freeCString(slice.ptr);
        const copy = host.allocator.dupe(u8, slice) catch return Value.initInt32(2);
        owned = copy;
        break :blk copy;
    } else return Value.initInt32(2);

    return Value.initInt32(host.net.write(id, bytes));
}

fn end(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const id = argId(ctx, args, 0) orelse return Value.initBool(false);
    return Value.initBool(host.net.end(id));
}

fn destroy(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const id = argId(ctx, args, 0) orelse return Value.initBool(false);
    return Value.initBool(host.net.destroy(id));
}

fn closeServer(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const id = argId(ctx, args, 0) orelse return Value.initBool(false);
    return Value.initBool(host.net.closeServer(id));
}

fn refValue(ctx: *quickjs.Context, args: []const quickjs.c.JSValue, index: usize) ?bool {
    const value = argValue(args, index);
    if (!value.isBool()) return null;
    return value.toBool(ctx) catch null;
}

fn serverSetRef(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const id = argId(ctx, args, 0) orelse return Value.initBool(false);
    const ref = refValue(ctx, args, 1) orelse return Value.initBool(false);
    return Value.initBool(host.net.setServerRef(id, ref, host.loop));
}

fn socketSetRef(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const id = argId(ctx, args, 0) orelse return Value.initBool(false);
    const ref = refValue(ctx, args, 1) orelse return Value.initBool(false);
    return Value.initBool(host.net.setSocketRef(id, ref, host.loop));
}

fn address(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const id = argId(ctx, args, 0) orelse return badIdObject(ctx);

    const object = Value.initObject(ctx);
    if (object.isException()) return object;

    if (host.net.addressOf(id)) |addr| {
        if (!setEndpoint(ctx, object, addr)) return abortObject(ctx, object);
        return object;
    }

    const payload = badIdObject(ctx);
    if (payload.isException()) return abortObject(ctx, object);
    if (!setField(ctx, object, "error", payload)) return abortObject(ctx, object);
    return object;
}

fn badIdObject(ctx: *quickjs.Context) Value {
    var info: core.ErrorInfo = .{ .code = "EBADF", .errno = -9, .syscall = "address" };
    const text = std.fmt.bufPrint(&info.buf, "address EBADF", .{}) catch "";
    info.len = @intCast(text.len);
    return buildError(ctx, info);
}

const Export = struct {
    name: [:0]const u8,
    func: quickjs.cfunc.Func,
    nargs: i32,
};

const module_exports = [_]Export{
    .{ .name = "listen", .func = listen, .nargs = 4 },
    .{ .name = "connect", .func = connect, .nargs = 3 },
    .{ .name = "write", .func = write, .nargs = 2 },
    .{ .name = "end", .func = end, .nargs = 1 },
    .{ .name = "destroy", .func = destroy, .nargs = 1 },
    .{ .name = "closeServer", .func = closeServer, .nargs = 1 },
    .{ .name = "serverSetRef", .func = serverSetRef, .nargs = 2 },
    .{ .name = "socketSetRef", .func = socketSetRef, .nargs = 2 },
    .{ .name = "address", .func = address, .nargs = 1 },
};

fn moduleInit(ctx: *quickjs.Context, def: *quickjs.ModuleDef) bool {
    inline for (module_exports) |entry| {
        const function = Value.initCFunction(ctx, entry.func, entry.name, entry.nargs);
        if (!def.setExport(ctx, entry.name, function)) return false;
    }
    return true;
}

pub fn initModule(ctx: *quickjs.Context) ?*quickjs.ModuleDef {
    const def = quickjs.ModuleDef.init(ctx, "node:_net", moduleInit) orelse return null;
    inline for (module_exports) |entry| {
        _ = def.addExport(ctx, entry.name);
    }
    return def;
}
