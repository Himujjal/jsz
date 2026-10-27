// Marshalling helpers shared by the `node:_*` native modules. Pure conversions
// only: no module surface, no error policy beyond the documented TypeErrors.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("host.zig").Host;

const Value = quickjs.Value;

fn throwArgType(
    host: *Host,
    ctx: *quickjs.Context,
    name: [:0]const u8,
) void {
    const message = std.fmt.allocPrintSentinel(
        host.allocator,
        "The \"{s}\" argument must be of type Buffer, TypedArray, or DataView",
        .{name},
        0,
    ) catch {
        _ = ctx.throwOutOfMemory();
        return;
    };
    defer host.allocator.free(message);
    _ = ctx.throwTypeError(message);
}

fn dupeBytes(host: *Host, ctx: *quickjs.Context, bytes: []const u8) ?[]u8 {
    return host.allocator.dupe(u8, bytes) catch {
        _ = ctx.throwOutOfMemory();
        return null;
    };
}

fn propLength(ctx: *quickjs.Context, object: Value, name: [*:0]const u8) ?usize {
    const prop = object.getPropertyStr(ctx, name);
    defer prop.deinit(ctx);
    const number = prop.toInt64(ctx) catch return null;
    if (number < 0) return null;
    return @intCast(number);
}

/// Copies the bytes behind a Buffer/TypedArray/DataView/ArrayBuffer.
pub fn toBytes(
    host: *Host,
    ctx: *quickjs.Context,
    value: Value,
    name: [:0]const u8,
) ?[]u8 {
    if (value.isArrayBuffer()) {
        const bytes = value.getArrayBuffer(ctx) orelse {
            throwArgType(host, ctx, name);
            return null;
        };
        return dupeBytes(host, ctx, bytes);
    }

    if (value.isObject() and value.getTypedArrayType() != null) {
        const view = value.getTypedArrayBuffer(ctx) orelse {
            throwArgType(host, ctx, name);
            return null;
        };
        defer view.value.deinit(ctx);
        const buffer = view.value.getArrayBuffer(ctx) orelse {
            throwArgType(host, ctx, name);
            return null;
        };
        const end = view.byte_offset +| view.byte_length;
        if (end > buffer.len) {
            throwArgType(host, ctx, name);
            return null;
        }
        return dupeBytes(host, ctx, buffer[view.byte_offset..end]);
    }

    // DataView is not a TypedArray in QuickJS, so read its window explicitly.
    if (value.isDataView()) {
        const buffer_value = value.getPropertyStr(ctx, "buffer");
        defer buffer_value.deinit(ctx);
        const buffer = buffer_value.getArrayBuffer(ctx) orelse {
            throwArgType(host, ctx, name);
            return null;
        };
        const offset = propLength(ctx, value, "byteOffset") orelse 0;
        const length = propLength(ctx, value, "byteLength") orelse (buffer.len -| offset);
        const end = offset +| length;
        if (end > buffer.len) {
            throwArgType(host, ctx, name);
            return null;
        }
        return dupeBytes(host, ctx, buffer[offset..end]);
    }

    throwArgType(host, ctx, name);
    return null;
}

/// Builds a Uint8Array that copies `bytes`.
pub fn fromBytes(ctx: *quickjs.Context, bytes: []const u8) Value {
    return Value.initUint8ArrayCopy(ctx, bytes);
}

/// Builds a JS string from UTF-8 bytes.
pub fn fromUtf8(ctx: *quickjs.Context, bytes: []const u8) Value {
    return Value.initStringLen(ctx, bytes);
}

/// Reads a string property, duped from the host allocator; null if not a string.
pub fn getString(ctx: *quickjs.Context, object: Value, name: [:0]const u8) ?[]u8 {
    const value = object.getPropertyStr(ctx, name);
    defer value.deinit(ctx);
    if (!value.isString()) return null;

    const host = ctx.getOpaque(Host) orelse return null;
    const slice = value.toZigSlice(ctx) orelse return null;
    defer ctx.freeCString(slice.ptr);

    return host.allocator.dupe(u8, slice) catch null;
}

/// Reads an integer property; null if it is missing or not a number.
pub fn getInt(ctx: *quickjs.Context, object: Value, name: [:0]const u8) ?i64 {
    const value = object.getPropertyStr(ctx, name);
    defer value.deinit(ctx);
    if (!value.isNumber()) return null;
    return value.toInt64(ctx) catch null;
}

/// Reads a boolean property; missing values are false.
pub fn getBool(ctx: *quickjs.Context, object: Value, name: [:0]const u8) bool {
    const value = object.getPropertyStr(ctx, name);
    defer value.deinit(ctx);
    if (value.isUndefined() or value.isNull()) return false;
    return value.toBool(ctx) catch false;
}

/// Sets a string property on a result object.
pub fn setString(ctx: *quickjs.Context, object: Value, name: [:0]const u8, text: []const u8) void {
    object.setPropertyStr(ctx, name, Value.initStringLen(ctx, text)) catch {};
}

/// Calls `function` with `this` and returns the result; the caller deinits it.
pub fn call(
    ctx: *quickjs.Context,
    function: Value,
    this: Value,
    args: []const Value,
) Value {
    return function.call(ctx, this, args);
}
