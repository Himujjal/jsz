const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("host.zig").Host;
const timers = @import("timers.zig");

pub fn sleep(
    ctx_opt: ?*quickjs.Context,
    _: quickjs.Value,
    args: []const quickjs.c.JSValue,
) quickjs.Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = ctx.getOpaque(Host) orelse
        return ctx.throwInternalError("jsz host is not initialized");

    const delay = timers.delayFromValue(ctx, if (args.len > 0) args[0] else null);
    const promise = quickjs.Value.initPromiseCapability(ctx);

    _ = host.loop.schedulePromise(delay, promise.resolve, promise.reject) catch {
        promise.value.deinit(ctx);
        return ctx.throwInternalError("failed to schedule sleep");
    };

    return promise.value;
}
