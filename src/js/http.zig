const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("host.zig").Host;
const core = @import("../http.zig");

const Value = quickjs.Value;
const Failure = core.Failure;
const HeaderPair = core.HeaderPair;

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

fn argId(ctx: *quickjs.Context, args: []const quickjs.c.JSValue, index: usize) ?u64 {
    const value = argValue(args, index);
    if (!value.isNumber()) return null;
    const number = value.toFloat64(ctx) catch return null;
    if (!std.math.isFinite(number) or number < 0) return null;
    if (number > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return null;
    if (@floor(number) != number) return null;
    return @intFromFloat(number);
}

fn argU16(ctx: *quickjs.Context, args: []const quickjs.c.JSValue, index: usize, default: u16) u16 {
    const value = argValue(args, index);
    if (!value.isNumber()) return default;
    const number = value.toFloat64(ctx) catch return default;
    if (!std.math.isFinite(number) or number < 0 or number > 65535) return default;
    if (@floor(number) != number) return default;
    return @intFromFloat(number);
}

fn argBool(ctx: *quickjs.Context, args: []const quickjs.c.JSValue, index: usize, default: bool) bool {
    const value = argValue(args, index);
    if (!value.isBool()) return default;
    return value.toBool(ctx) catch default;
}

/// Parses the HTTP status argument, accepting any printable three-digit code.
fn argStatus(ctx: *quickjs.Context, args: []const quickjs.c.JSValue, index: usize) ?u16 {
    const value = argValue(args, index);
    if (!value.isNumber()) return null;
    const number = value.toFloat64(ctx) catch return null;
    if (!std.math.isFinite(number) or number < 100 or number > 999) return null;
    if (@floor(number) != number) return null;
    return @intFromFloat(number);
}

/// Copies a string argument; null means "absent or not a string".
fn dupeStringArg(
    host: *Host,
    ctx: *quickjs.Context,
    args: []const quickjs.c.JSValue,
    index: usize,
) ?[]u8 {
    const value = argValue(args, index);
    if (!value.isString()) return null;
    const slice = value.toZigSlice(ctx) orelse return null;
    defer ctx.freeCString(slice.ptr);
    return host.allocator.dupe(u8, slice) catch null;
}

fn setField(ctx: *quickjs.Context, object: Value, name: [*:0]const u8, value: Value) bool {
    object.setPropertyStr(ctx, name, value) catch return false;
    return true;
}

fn abortObject(ctx: *quickjs.Context, object: Value) Value {
    object.deinit(ctx);
    return .undefined;
}

fn buildFailure(ctx: *quickjs.Context, failure: Failure) Value {
    const object = Value.initObject(ctx);
    if (object.isException()) return object;

    var ok = setField(ctx, object, "code", Value.initString(ctx, failure.code));
    if (ok) ok = setField(ctx, object, "message", Value.initStringLen(ctx, failure.message));
    if (ok) ok = setField(ctx, object, "errno", Value.initInt32(failure.errno));
    if (ok) ok = setField(ctx, object, "syscall", Value.initStringLen(ctx, failure.syscall));
    if (!ok) return abortObject(ctx, object);
    return object;
}

fn buildAddress(ctx: *quickjs.Context, info: core.AddressInfo) Value {
    const object = Value.initObject(ctx);
    if (object.isException()) return object;

    var ok = setField(ctx, object, "address", Value.initStringLen(ctx, info.address));
    if (ok) ok = setField(ctx, object, "family", Value.initStringLen(ctx, info.family));
    if (ok) ok = setField(ctx, object, "port", Value.initInt32(info.port));
    if (!ok) return abortObject(ctx, object);
    return object;
}

fn freePairItems(allocator: std.mem.Allocator, pairs: []HeaderPair) void {
    for (pairs) |pair| {
        allocator.free(pair.name);
        allocator.free(pair.value);
    }
}

fn freePairs(allocator: std.mem.Allocator, pairs: []HeaderPair) void {
    freePairItems(allocator, pairs);
    allocator.free(pairs);
}

fn hasLineBreak(text: []const u8) bool {
    return std.mem.findScalar(u8, text, '\r') != null or
        std.mem.findScalar(u8, text, '\n') != null;
}

fn isTokenChar(c: u8) bool {
    return switch (c) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => std.ascii.isAlphanumeric(c),
    };
}

/// HTTP writers assert a non-empty token, so reject malformed names here.
fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!isTokenChar(c)) return false;
    }
    return true;
}

/// Parses the flat `[name, value, ...]` array into owned pairs.
fn parseHeaderPairs(
    host: *Host,
    ctx: *quickjs.Context,
    value: Value,
) ?[]HeaderPair {
    var list: std.ArrayList(HeaderPair) = .empty;
    var transferred = false;
    defer if (!transferred) {
        freePairItems(host.allocator, list.items);
        list.deinit(host.allocator);
    };

    if (!value.isArray()) {
        const empty = list.toOwnedSlice(host.allocator) catch return null;
        transferred = true;
        return empty;
    }

    const length = value.getLength(ctx) catch 0;
    const count: usize = if (length > 0) @intCast(length) else 0;
    if (count % 2 != 0) return null;

    var index: usize = 0;
    while (index < count) : (index += 2) {
        const name_value = value.getPropertyUint32(ctx, @intCast(index));
        defer name_value.deinit(ctx);
        const entry_value = value.getPropertyUint32(ctx, @intCast(index + 1));
        defer entry_value.deinit(ctx);
        if (!name_value.isString() or !entry_value.isString()) return null;

        const name_slice = name_value.toZigSlice(ctx) orelse return null;
        defer ctx.freeCString(name_slice.ptr);
        const value_slice = entry_value.toZigSlice(ctx) orelse return null;
        defer ctx.freeCString(value_slice.ptr);

        // The HTTP writer asserts on malformed names and on CR/LF in values.
        if (!validHeaderName(name_slice) or hasLineBreak(value_slice)) return null;

        const name = host.allocator.dupe(u8, name_slice) catch return null;
        const entry = host.allocator.dupe(u8, value_slice) catch {
            host.allocator.free(name);
            return null;
        };
        list.append(host.allocator, .{ .name = name, .value = entry }) catch {
            host.allocator.free(name);
            host.allocator.free(entry);
            return null;
        };
    }

    const owned = list.toOwnedSlice(host.allocator) catch return null;
    transferred = true;
    return owned;
}

/// `listen(host, port, backlog, dispatch[, cert, key])`.
fn listen(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const owned_host = dupeStringArg(host, ctx, args, 0);
    defer if (owned_host) |text| host.allocator.free(text);
    const host_text: []const u8 = owned_host orelse "";

    const port = argU16(ctx, args, 1, 0);
    const backlog_value = argU16(ctx, args, 2, 511);
    const backlog: u31 = @intCast(@min(backlog_value, std.math.maxInt(u31)));

    const dispatch = argValue(args, 3);
    if (!dispatch.isFunction(ctx)) {
        _ = ctx.throwTypeError("The \"dispatch\" argument must be of type function");
        return .undefined;
    }

    const owned_cert = dupeStringArg(host, ctx, args, 4);
    defer if (owned_cert) |text| host.allocator.free(text);
    const owned_key = dupeStringArg(host, ctx, args, 5);
    defer if (owned_key) |text| host.allocator.free(text);
    const owned_ca = dupeStringArg(host, ctx, args, 6);
    defer if (owned_ca) |text| host.allocator.free(text);

    const request_cert = argBool(ctx, args, 7, false);
    const reject_unauthorized = argBool(ctx, args, 8, true);

    // A certificate without a key cannot start a TLS listener; the facade
    // rejects that case before it reaches here.
    const tls: ?core.TlsMaterial = if (owned_cert != null and owned_key != null)
        .{
            .cert = owned_cert.?,
            .key = owned_key.?,
            .ca = owned_ca orelse "",
            .request_cert = request_cert,
            .reject_unauthorized = reject_unauthorized,
        }
    else
        null;

    const result = host.http.listen(ctx, host_text, port, backlog, dispatch, tls) catch
        return ctx.throwInternalError("failed to start the HTTP server");

    const object = Value.initObject(ctx);
    if (object.isException()) {
        switch (result) {
            .ok => {},
            .failure => |failure| {
                var copy = failure;
                copy.deinit(host.allocator);
            },
        }
        return object;
    }

    switch (result) {
        .ok => |ok| {
            host.loop.ref();
            var success = setField(ctx, object, "id", Value.initFloat64(@floatFromInt(ok.id)));
            if (success) success = setField(ctx, object, "address", Value.initStringLen(ctx, ok.address));
            if (success) success = setField(ctx, object, "family", Value.initStringLen(ctx, ok.family));
            if (success) success = setField(ctx, object, "port", Value.initInt32(ok.port));
            if (!success) return abortObject(ctx, object);
        },
        .failure => |failure| {
            var copy = failure;
            defer copy.deinit(host.allocator);
            const payload = buildFailure(ctx, copy);
            if (payload.isException()) return abortObject(ctx, object);
            if (!setField(ctx, object, "error", payload)) return abortObject(ctx, object);
        },
    }
    return object;
}

/// `respond(connId, status, statusMessage, headerPairs, body, keepAlive)`.
fn respond(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const conn_id = argId(ctx, args, 0) orelse return Value.initBool(false);
    const status = argStatus(ctx, args, 1) orelse return Value.initBool(false);

    const reason = dupeStringArg(host, ctx, args, 2);

    const pairs = parseHeaderPairs(host, ctx, argValue(args, 3)) orelse {
        if (reason) |text| host.allocator.free(text);
        return Value.initBool(false);
    };

    const body_slice: []const u8 = if (argValue(args, 4).getUint8Array(ctx)) |bytes| bytes else "";
    const body = host.allocator.dupe(u8, body_slice) catch {
        if (reason) |text| host.allocator.free(text);
        freePairs(host.allocator, pairs);
        return ctx.throwOutOfMemory();
    };

    const keep_alive = argBool(ctx, args, 5, true);
    return Value.initBool(host.http.respond(conn_id, status, reason, pairs, body, keep_alive));
}

/// `streamStart(connId, status, statusMessage, headerPairs, keepAlive)`.
fn streamStart(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const conn_id = argId(ctx, args, 0) orelse return Value.initBool(false);
    const status = argStatus(ctx, args, 1) orelse return Value.initBool(false);

    const reason = dupeStringArg(host, ctx, args, 2);

    const pairs = parseHeaderPairs(host, ctx, argValue(args, 3)) orelse {
        if (reason) |text| host.allocator.free(text);
        return Value.initBool(false);
    };

    const keep_alive = argBool(ctx, args, 4, true);
    return Value.initBool(host.http.streamStart(conn_id, status, reason, pairs, keep_alive));
}

/// `streamWrite(connId, chunk)`; false reports native backpressure.
fn streamWrite(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const conn_id = argId(ctx, args, 0) orelse return Value.initBool(false);
    const chunk: []const u8 = if (argValue(args, 1).getUint8Array(ctx)) |bytes| bytes else "";
    return Value.initBool(host.http.streamWrite(conn_id, chunk));
}

/// `streamEnd(connId)`.
fn streamEnd(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const conn_id = argId(ctx, args, 0) orelse return Value.initBool(false);
    return Value.initBool(host.http.streamEnd(conn_id));
}

/// `streamAbort(connId)`.
fn streamAbort(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const conn_id = argId(ctx, args, 0) orelse return Value.initBool(false);
    return Value.initBool(host.http.streamAbort(conn_id));
}

fn closeServer(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const id = argId(ctx, args, 0) orelse return .undefined;
    _ = host.http.closeServer(id);
    return .undefined;
}

fn serverSetRef(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const id = argId(ctx, args, 0) orelse return Value.initBool(false);
    const ref_value = argValue(args, 1);
    if (!ref_value.isBool()) return Value.initBool(false);
    const ref = ref_value.toBool(ctx) catch return Value.initBool(false);
    return Value.initBool(host.http.setRef(id, ref, host.loop));
}

fn address(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const id = argId(ctx, args, 0) orelse return .undefined;

    if (host.http.address(id)) |info| return buildAddress(ctx, info);

    const object = Value.initObject(ctx);
    if (object.isException()) return object;
    const error_object = Value.initObject(ctx);
    if (error_object.isException()) return abortObject(ctx, object);
    _ = setField(ctx, error_object, "code", Value.initString(ctx, "ERR_SERVER_NOT_RUNNING"));
    _ = setField(ctx, error_object, "message", Value.initString(ctx, "Server is not running."));
    if (!setField(ctx, object, "error", error_object)) return abortObject(ctx, object);
    return object;
}

const Export = struct {
    name: [:0]const u8,
    func: quickjs.cfunc.Func,
    nargs: i32,
};

const module_exports = [_]Export{
    .{ .name = "listen", .func = listen, .nargs = 9 },
    .{ .name = "respond", .func = respond, .nargs = 6 },
    .{ .name = "streamStart", .func = streamStart, .nargs = 5 },
    .{ .name = "streamWrite", .func = streamWrite, .nargs = 2 },
    .{ .name = "streamEnd", .func = streamEnd, .nargs = 1 },
    .{ .name = "streamAbort", .func = streamAbort, .nargs = 1 },
    .{ .name = "closeServer", .func = closeServer, .nargs = 1 },
    .{ .name = "serverSetRef", .func = serverSetRef, .nargs = 2 },
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
    const def = quickjs.ModuleDef.init(ctx, "node:_http", moduleInit) orelse return null;
    inline for (module_exports) |entry| {
        _ = def.addExport(ctx, entry.name);
    }
    return def;
}
