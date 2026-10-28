// Native half of `node:_pkcs12`.
//
// The JS facade only needs a synchronous conversion from PFX bytes to a PEM
// certificate chain and key. All parsing is pure Zig; errors carry Node-style
// codes so the facade can rethrow them unchanged.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("host.zig").Host;
const value_util = @import("value.zig");
const pkcs12 = @import("../pkcs12.zig");

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

fn setField(
    ctx: *quickjs.Context,
    object: Value,
    name: [*:0]const u8,
    value: Value,
) bool {
    object.setPropertyStr(ctx, name, value) catch return false;
    return true;
}

fn throwCodedError(
    ctx: *quickjs.Context,
    code: []const u8,
    message: []const u8,
) Value {
    const error_value = Value.initError(ctx);
    if (error_value.isException()) {
        error_value.deinit(ctx);
        return ctx.throwOutOfMemory();
    }

    error_value.setPropertyStr(ctx, "code", Value.initStringLen(ctx, code)) catch {};
    error_value.setPropertyStr(ctx, "message", Value.initStringLen(ctx, message)) catch {};

    // JS_Throw consumes the error object and returns JS_EXCEPTION.
    return error_value.throw(ctx);
}

fn throwParseError(ctx: *quickjs.Context, err: pkcs12.ParseError) Value {
    return switch (err) {
        error.InvalidPassword => throwCodedError(
            ctx,
            "ERR_INVALID_PASSWORD",
            "PKCS#12 passphrase is incorrect",
        ),
        error.InvalidPfx => throwCodedError(
            ctx,
            "ERR_INVALID_PFX",
            "Invalid PKCS#12 data",
        ),
        error.UnsupportedPfx => throwCodedError(
            ctx,
            "ERR_INVALID_PFX",
            "Unsupported PKCS#12 algorithm",
        ),
        error.OutOfMemory => ctx.throwOutOfMemory(),
    };
}

fn parseFn(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    // `toBytes` already threw a TypeError; surface the exception marker.
    const bytes = value_util.toBytes(host, ctx, argValue(args, 0), "bytes") orelse
        return Value.exception;
    defer host.allocator.free(bytes);

    const passphrase_value = argValue(args, 1);
    if (!passphrase_value.isString()) {
        return ctx.throwTypeError("The \"passphrase\" argument must be of type string");
    }

    const passphrase = passphrase_value.toZigSlice(ctx) orelse
        return ctx.throwInternalError("failed to read passphrase argument");
    defer ctx.freeCString(passphrase.ptr);

    var bundle = pkcs12.parse(host.allocator, bytes, passphrase) catch |err| {
        return throwParseError(ctx, err);
    };
    defer bundle.deinit(host.allocator);

    const object = Value.initObject(ctx);
    if (object.isException()) return object;

    if (!setField(ctx, object, "cert", Value.initStringLen(ctx, bundle.cert_pem))) {
        object.deinit(ctx);
        return ctx.throwOutOfMemory();
    }
    if (!setField(ctx, object, "key", Value.initStringLen(ctx, bundle.key_pem))) {
        object.deinit(ctx);
        return ctx.throwOutOfMemory();
    }
    return object;
}

fn moduleInit(ctx: *quickjs.Context, def: *quickjs.ModuleDef) bool {
    const function = Value.initCFunction(ctx, parseFn, "parse", 2);
    return def.setExport(ctx, "parse", function);
}

pub fn initModule(ctx: *quickjs.Context) ?*quickjs.ModuleDef {
    const def = quickjs.ModuleDef.init(ctx, "node:_pkcs12", moduleInit) orelse return null;
    _ = def.addExport(ctx, "parse");
    return def;
}
