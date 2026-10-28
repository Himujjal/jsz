// Native half of `node:_fetch`.
//
// Argument parsing and validation run on the JS task; the request itself runs
// in a zio task owned by `Fetch`. Only this module and `src/fetch.zig` touch
// both worlds, and the split keeps QuickJS values on the JS task.

const std = @import("std");
const quickjs = @import("quickjs");
const dusty = @import("dusty");
const Host = @import("host.zig").Host;
const value_util = @import("value.zig");
const fetch = @import("../fetch.zig");

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

const Invalid = struct {
    code: [:0]const u8 = "ERR_INVALID_ARG_TYPE",
    message: [:0]const u8 = "invalid argument",
};

const ParseError = error{ Invalid, OutOfMemory, Exception };

fn invalidArg(
    invalid: *Invalid,
    buffer: *[512]u8,
    code: [:0]const u8,
    comptime fmt: []const u8,
    fmt_args: anytype,
) ParseError {
    invalid.code = code;
    invalid.message = std.fmt.bufPrintSentinel(buffer, fmt, fmt_args, 0) catch "invalid argument";
    return error.Invalid;
}

fn dupeString(
    ctx: *quickjs.Context,
    allocator: std.mem.Allocator,
    value: Value,
) error{OutOfMemory}!?[]u8 {
    if (!value.isString()) return null;
    const slice = value.toZigSlice(ctx) orelse return error.OutOfMemory;
    defer ctx.freeCString(slice.ptr);
    return try allocator.dupe(u8, slice);
}

/// Rejects names/values that the HTTP writer would refuse.
fn headerHasInvalidChars(text: []const u8) bool {
    return std.mem.indexOfAny(u8, text, "\r\n") != null;
}

/// Reads one optional TLS string property; `null` when absent or null.
fn tlsString(
    host: *Host,
    ctx: *quickjs.Context,
    object: Value,
    name: [:0]const u8,
    invalid: *Invalid,
    buffer: *[512]u8,
) ParseError!?[]u8 {
    const property = object.getPropertyStr(ctx, name);
    defer property.deinit(ctx);
    if (property.isUndefined() or property.isNull()) return null;
    if (!property.isString()) {
        return invalidArg(
            invalid,
            buffer,
            "ERR_INVALID_ARG_TYPE",
            "The TLS \"{s}\" option must be of type string",
            .{name},
        );
    }
    return (try dupeString(ctx, host.allocator, property)) orelse error.OutOfMemory;
}

/// `{ ca?, cert?, key?, rejectUnauthorized? }`; every string is owned.
fn parseTls(
    host: *Host,
    ctx: *quickjs.Context,
    value: Value,
    invalid: *Invalid,
    buffer: *[512]u8,
) ParseError!fetch.TlsRequest {
    var tls: fetch.TlsRequest = .{};
    errdefer tls.deinit(host.allocator);

    tls.ca = try tlsString(host, ctx, value, "ca", invalid, buffer);
    tls.cert = try tlsString(host, ctx, value, "cert", invalid, buffer);
    tls.key = try tlsString(host, ctx, value, "key", invalid, buffer);

    const reject = value.getPropertyStr(ctx, "rejectUnauthorized");
    defer reject.deinit(ctx);
    if (reject.isBool()) tls.reject_unauthorized = reject.toBool(ctx) catch true;

    // Dusty loads the pair together; a lone half is a mistake, not a default.
    if ((tls.cert == null) != (tls.key == null)) {
        return invalidArg(
            invalid,
            buffer,
            "ERR_INVALID_ARG_VALUE",
            "The TLS \"cert\" and \"key\" options must be provided together",
            .{},
        );
    }

    return tls;
}

/// Reads a callback argument; `undefined` when absent, null, or not a function.
fn callbackArg(
    ctx: *quickjs.Context,
    args: []const quickjs.c.JSValue,
    index: usize,
    name: [:0]const u8,
    invalid: *Invalid,
    buffer: *[512]u8,
) ParseError!Value {
    const raw = argValue(args, index);
    if (raw.isUndefined() or raw.isNull()) return .undefined;
    if (!raw.isFunction(ctx)) {
        return invalidArg(
            invalid,
            buffer,
            "ERR_INVALID_ARG_TYPE",
            "The \"{s}\" argument must be of type function",
            .{name},
        );
    }
    return raw.dup(ctx);
}

const ParsedHeaders = struct {
    pairs: []fetch.HeaderPair,
    table: dusty.Headers,
};

const ParseOptions = struct {
    /// `http.request` allows a body on every method; `fetch` does not.
    allow_any_method: bool = false,
    /// When set, the redirect limit is fixed instead of read from argument 4.
    fixed_redirects: ?u8 = null,
    /// Argument index holding a millisecond timeout.
    timeout_index: ?usize = null,
    decompress: bool = true,
};

fn parseHeaderPairs(
    host: *Host,
    ctx: *quickjs.Context,
    value: Value,
    invalid: *Invalid,
    buffer: *[512]u8,
) ParseError!ParsedHeaders {
    if (value.isUndefined() or value.isNull()) return .{ .pairs = &.{}, .table = .{} };
    if (!value.isArray()) {
        return invalidArg(invalid, buffer, "ERR_INVALID_ARG_TYPE", "The \"headers\" argument must be a flat array", .{});
    }

    const length_value = value.getPropertyStr(ctx, "length");
    defer length_value.deinit(ctx);
    const length = length_value.toInt64(ctx) catch
        return invalidArg(invalid, buffer, "ERR_INVALID_ARG_TYPE", "The \"headers\" argument must be a flat array", .{});
    if (length < 0 or @rem(length, 2) != 0) {
        return invalidArg(
            invalid,
            buffer,
            "ERR_INVALID_ARG_VALUE",
            "The \"headers\" argument must contain an even number of entries",
            .{},
        );
    }

    const count: usize = @intCast(@divTrunc(length, 2));
    if (count == 0) return .{ .pairs = &.{}, .table = .{} };

    const pairs = try host.allocator.alloc(fetch.HeaderPair, count);
    errdefer host.allocator.free(pairs);

    var table = dusty.Headers.init(host.allocator, count) catch return error.OutOfMemory;
    errdefer table.deinit(host.allocator);

    var filled: usize = 0;
    errdefer {
        for (pairs[0..filled]) |pair| {
            host.allocator.free(pair.name);
            host.allocator.free(pair.value);
        }
    }

    for (0..count) |index| {
        const name = try headerElement(host, ctx, value, index * 2, invalid, buffer);
        errdefer host.allocator.free(name);
        const header_value = try headerElement(host, ctx, value, index * 2 + 1, invalid, buffer);
        errdefer host.allocator.free(header_value);

        if (name.len == 0 or std.mem.indexOfScalar(u8, name, ':') != null or headerHasInvalidChars(name)) {
            return invalidArg(
                invalid,
                buffer,
                "ERR_INVALID_HTTP_TOKEN",
                "The header name \"{s}\" is not a valid HTTP token",
                .{name},
            );
        }
        if (headerHasInvalidChars(header_value)) {
            return invalidArg(
                invalid,
                buffer,
                "ERR_INVALID_CHAR",
                "The header value for \"{s}\" contains an invalid character",
                .{name},
            );
        }

        table.add(name, header_value) catch
            return invalidArg(invalid, buffer, "ERR_INVALID_ARG_VALUE", "Too many request headers", .{});
        pairs[index] = .{ .name = name, .value = header_value };
        filled = index + 1;
    }

    return .{ .pairs = pairs, .table = table };
}

fn headerElement(
    host: *Host,
    ctx: *quickjs.Context,
    array: Value,
    index: usize,
    invalid: *Invalid,
    buffer: *[512]u8,
) ParseError![]u8 {
    const element = array.getPropertyUint32(ctx, @intCast(index));
    defer element.deinit(ctx);

    const text = (try dupeString(ctx, host.allocator, element)) orelse
        return invalidArg(
            invalid,
            buffer,
            "ERR_INVALID_ARG_TYPE",
            "The \"headers\" argument must contain only strings",
            .{},
        );
    return text;
}

fn parseRequest(
    host: *Host,
    ctx: *quickjs.Context,
    args: []const quickjs.c.JSValue,
    invalid: *Invalid,
    buffer: *[512]u8,
    options: ParseOptions,
) ParseError!fetch.Job {
    const allocator = host.allocator;

    const url_value = argValue(args, 0);
    const url = (try dupeString(ctx, allocator, url_value)) orelse
        return invalidArg(invalid, buffer, "ERR_INVALID_ARG_TYPE", "The \"url\" argument must be of type string", .{});
    errdefer allocator.free(url);

    const method_value = argValue(args, 1);
    if (!method_value.isString()) {
        return invalidArg(invalid, buffer, "ERR_INVALID_ARG_TYPE", "The \"method\" argument must be of type string", .{});
    }
    const method_slice = method_value.toZigSlice(ctx) orelse {
        return invalidArg(invalid, buffer, "ERR_INVALID_ARG_TYPE", "The \"method\" argument must be of type string", .{});
    };
    defer ctx.freeCString(method_slice.ptr);

    var method_buffer: [32]u8 = undefined;
    if (method_slice.len > method_buffer.len) {
        return invalidArg(
            invalid,
            buffer,
            "ERR_INVALID_ARG_VALUE",
            "The \"{s}\" method is not supported",
            .{method_slice},
        );
    }

    const method = std.meta.stringToEnum(dusty.Method, std.ascii.lowerString(&method_buffer, method_slice)) orelse
        return invalidArg(
            invalid,
            buffer,
            "ERR_INVALID_ARG_VALUE",
            "The \"{s}\" method is not supported",
            .{method_slice},
        );

    var parsed_headers = try parseHeaderPairs(host, ctx, argValue(args, 2), invalid, buffer);
    errdefer {
        for (parsed_headers.pairs) |pair| {
            allocator.free(pair.name);
            allocator.free(pair.value);
        }
        if (parsed_headers.pairs.len > 0) allocator.free(parsed_headers.pairs);
        parsed_headers.table.deinit(allocator);
    }

    var body: []u8 = &.{};
    var has_body = false;
    const body_value = argValue(args, 3);
    if (!body_value.isUndefined() and !body_value.isNull()) {
        body = value_util.toBytes(host, ctx, body_value, "body") orelse return error.Exception;
        has_body = true;
    }
    errdefer if (body.len > 0) allocator.free(body);

    if (has_body and !options.allow_any_method and !methodHasBody(method)) {
        return invalidArg(
            invalid,
            buffer,
            "ERR_INVALID_ARG_VALUE",
            "Request with {s} method cannot have a body",
            .{method.name()},
        );
    }

    var redirects: i64 = options.fixed_redirects orelse 5;
    const redirect_value = argValue(args, 4);
    if (options.fixed_redirects == null and redirect_value.isNumber()) {
        const number = redirect_value.toFloat64(ctx) catch 5;
        if (std.math.isFinite(number)) {
            const clamped = @max(0, @min(number, 255));
            redirects = @intFromFloat(clamped);
        }
    }

    var timeout_ms: ?u32 = null;
    if (options.timeout_index) |index| {
        const timeout_value = argValue(args, index);
        if (timeout_value.isNumber()) {
            const number = timeout_value.toFloat64(ctx) catch 0;
            if (std.math.isFinite(number) and number > 0) {
                const clamped = @min(number, @as(f64, @floatFromInt(std.math.maxInt(u32))));
                timeout_ms = @intFromFloat(clamped);
            }
        }
    }

    var id: u64 = 0;
    if (argValue(args, 5).isNumber()) {
        const number = argValue(args, 5).toFloat64(ctx) catch 0;
        if (std.math.isFinite(number) and number >= 0 and number <= 9007199254740992.0) {
            id = @intFromFloat(number);
        }
    }

    // Optional trailing arguments: TLS options, then the streaming callbacks.
    var tls: fetch.TlsRequest = .{};
    errdefer tls.deinit(allocator);

    const tls_value = argValue(args, 6);
    if (!tls_value.isUndefined() and !tls_value.isNull()) {
        if (!tls_value.isObject()) {
            return invalidArg(
                invalid,
                buffer,
                "ERR_INVALID_ARG_TYPE",
                "The \"tls\" argument must be of type object",
                .{},
            );
        }
        tls = try parseTls(host, ctx, tls_value, invalid, buffer);
    }

    const on_chunk = try callbackArg(ctx, args, 7, "onChunk", invalid, buffer);
    errdefer on_chunk.deinit(ctx);
    const on_end = try callbackArg(ctx, args, 8, "onEnd", invalid, buffer);
    errdefer on_end.deinit(ctx);
    const on_error = try callbackArg(ctx, args, 9, "onError", invalid, buffer);
    errdefer on_error.deinit(ctx);

    return .{
        .id = id,
        .url = url,
        .method = method,
        .header_pairs = parsed_headers.pairs,
        .header_table = parsed_headers.table,
        .body = body,
        .has_body = has_body,
        .max_redirects = @intCast(redirects),
        .timeout_ms = timeout_ms,
        .decompress = options.decompress,
        .tls = tls,
        .stream = on_chunk.isFunction(ctx),
        .on_chunk = on_chunk,
        .on_end = on_end,
        .on_error = on_error,
    };
}

/// Mirrors `std.http.Method.requestHasBody` for the dusty method set.
fn methodHasBody(method: dusty.Method) bool {
    return switch (method) {
        .post, .put, .patch => true,
        else => false,
    };
}

fn submit(host: *Host, ctx: *quickjs.Context, job: fetch.Job) Value {
    const promise = Value.initPromiseCapability(ctx);

    const heap = host.allocator.create(fetch.Job) catch {
        var temp = job;
        temp.allocator = host.allocator;
        temp.deinitValues(ctx);
        temp.freeRequest();
        promise.deinit(ctx);
        return ctx.throwOutOfMemory();
    };

    heap.* = job;
    heap.resolve = promise.resolve;
    heap.reject = promise.reject;

    host.fetch.submit(heap) catch {
        heap.deinitValues(ctx);
        heap.freeRequest();
        host.allocator.destroy(heap);
        promise.value.deinit(ctx);
        return ctx.throwInternalError("failed to start fetch request");
    };

    return promise.value;
}

fn rejectInvalid(ctx: *quickjs.Context, invalid: Invalid) Value {
    const promise = Value.initPromiseCapability(ctx);

    const error_value = ctx.newTypeError(invalid.message);
    defer error_value.deinit(ctx);
    error_value.setPropertyStr(ctx, "code", Value.initString(ctx, invalid.code)) catch {};

    const ignored = promise.reject.call(ctx, .undefined, &.{error_value});
    ignored.deinit(ctx);
    promise.resolve.deinit(ctx);
    promise.reject.deinit(ctx);
    return promise.value;
}

fn parseJob(
    host: *Host,
    ctx: *quickjs.Context,
    args: []const quickjs.c.JSValue,
    options: ParseOptions,
) Value {
    var buffer: [512]u8 = undefined;
    var invalid: Invalid = .{};

    const job = parseRequest(host, ctx, args, &invalid, &buffer, options) catch |err| switch (err) {
        // `toBytes` already threw a TypeError; let the exception propagate.
        error.Exception => return .undefined,
        error.OutOfMemory => return ctx.throwOutOfMemory(),
        error.Invalid => return rejectInvalid(ctx, invalid),
    };

    return submit(host, ctx, job);
}

fn fetchFn(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    return parseJob(host, ctx, args, .{});
}

/// `http.request` shares the buffered dusty client but keeps the raw body,
/// disables redirects, and permits a body on every method.
fn requestFn(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    return parseJob(host, ctx, args, .{
        .allow_any_method = true,
        .fixed_redirects = 0,
        .timeout_index = 4,
        .decompress = false,
    });
}

fn abortFn(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const id_value = argValue(args, 0);
    if (!id_value.isNumber()) return Value.initBool(false);
    const number = id_value.toFloat64(ctx) catch return Value.initBool(false);
    if (!std.math.isFinite(number) or number < 0 or number > 9007199254740992.0) {
        return Value.initBool(false);
    }
    return Value.initBool(host.fetch.abort(@intFromFloat(number)));
}

/// Grants a streaming request one more body read; false if it is not waiting.
fn ackFn(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const id_value = argValue(args, 0);
    if (!id_value.isNumber()) return Value.initBool(false);
    const number = id_value.toFloat64(ctx) catch return Value.initBool(false);
    if (!std.math.isFinite(number) or number < 0 or number > 9007199254740992.0) {
        return Value.initBool(false);
    }
    return Value.initBool(host.fetch.ack(@intFromFloat(number)));
}

fn moduleInit(ctx: *quickjs.Context, def: *quickjs.ModuleDef) bool {
    const fetch_function = Value.initCFunction(ctx, fetchFn, "fetch", 10);
    if (!def.setExport(ctx, "fetch", fetch_function)) return false;
    const request_function = Value.initCFunction(ctx, requestFn, "request", 10);
    if (!def.setExport(ctx, "request", request_function)) return false;
    const abort_function = Value.initCFunction(ctx, abortFn, "abort", 1);
    if (!def.setExport(ctx, "abort", abort_function)) return false;
    const ack_function = Value.initCFunction(ctx, ackFn, "ack", 1);
    return def.setExport(ctx, "ack", ack_function);
}

pub fn initModule(ctx: *quickjs.Context) ?*quickjs.ModuleDef {
    const def = quickjs.ModuleDef.init(ctx, "node:_fetch", moduleInit) orelse return null;
    _ = def.addExport(ctx, "fetch");
    _ = def.addExport(ctx, "request");
    _ = def.addExport(ctx, "abort");
    _ = def.addExport(ctx, "ack");
    return def;
}
