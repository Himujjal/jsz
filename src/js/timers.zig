const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("host.zig").Host;

pub fn setTimeout(
    ctx_opt: ?*quickjs.Context,
    _: quickjs.Value,
    args: []const quickjs.c.JSValue,
) quickjs.Value {
    return schedule(ctx_opt, args, false);
}

pub fn setInterval(
    ctx_opt: ?*quickjs.Context,
    _: quickjs.Value,
    args: []const quickjs.c.JSValue,
) quickjs.Value {
    return schedule(ctx_opt, args, true);
}

pub fn clearTimeout(
    ctx_opt: ?*quickjs.Context,
    _: quickjs.Value,
    args: []const quickjs.c.JSValue,
) quickjs.Value {
    return clear(ctx_opt, args);
}

pub fn clearInterval(
    ctx_opt: ?*quickjs.Context,
    _: quickjs.Value,
    args: []const quickjs.c.JSValue,
) quickjs.Value {
    return clear(ctx_opt, args);
}

pub fn delayFromValue(ctx: *quickjs.Context, value: ?quickjs.c.JSValue) u64 {
    const raw = if (value) |v| quickjs.Value.fromCVal(v) else quickjs.Value.undefined;
    if (raw.isUndefined() or raw.isNull()) return 0;

    const number = raw.toFloat64(ctx) catch return 0;
    if (std.math.isNan(number) or number <= 0) return 0;
    return @intFromFloat(@min(number, 2_147_483_647.0));
}

fn schedule(
    ctx_opt: ?*quickjs.Context,
    args: []const quickjs.c.JSValue,
    repeat: bool,
) quickjs.Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = ctx.getOpaque(Host) orelse
        return ctx.throwInternalError("jsz host is not initialized");

    if (args.len == 0) return ctx.throwTypeError("callback is required");

    const callback = quickjs.Value.fromCVal(args[0]);
    if (!callback.isFunction(ctx)) {
        return ctx.throwTypeError("callback must be a function");
    }

    const delay = delayFromValue(ctx, if (args.len > 1) args[1] else null);
    const callback_copy = callback.dup(ctx);

    const callback_args = makeArgs(host, ctx, if (args.len > 2) args[2..] else &.{}) catch {
        callback_copy.deinit(ctx);
        return ctx.throwInternalError("out of memory");
    };

    const id = host.loop.schedule(delay, repeat, callback_copy, callback_args) catch {
        return ctx.throwInternalError("failed to schedule timer");
    };

    return quickjs.Value.initInt64(@intCast(id));
}

fn clear(
    ctx_opt: ?*quickjs.Context,
    args: []const quickjs.c.JSValue,
) quickjs.Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = ctx.getOpaque(Host) orelse return .undefined;

    if (args.len == 0) return .undefined;
    const id = quickjs.Value.fromCVal(args[0]).toUint32(ctx) catch return .undefined;
    _ = host.loop.cancel(id);
    return .undefined;
}

fn makeArgs(
    host: *Host,
    ctx: *quickjs.Context,
    raw: []const quickjs.c.JSValue,
) ![]quickjs.Value {
    const values = try host.allocator.alloc(quickjs.Value, raw.len);
    errdefer host.allocator.free(values);

    for (raw, 0..) |value, index| {
        values[index] = quickjs.Value.fromCVal(value).dup(ctx);
    }
    return values;
}
