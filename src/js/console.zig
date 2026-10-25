const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("host.zig").Host;

pub fn log(
    ctx_opt: ?*quickjs.Context,
    _: quickjs.Value,
    args: []const quickjs.c.JSValue,
) quickjs.Value {
    return write(ctx_opt, args);
}

pub fn writeError(
    ctx_opt: ?*quickjs.Context,
    _: quickjs.Value,
    args: []const quickjs.c.JSValue,
) quickjs.Value {
    return write(ctx_opt, args);
}

fn write(
    ctx_opt: ?*quickjs.Context,
    args: []const quickjs.c.JSValue,
) quickjs.Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = ctx.getOpaque(Host) orelse return .undefined;

    for (args, 0..) |raw, index| {
        if (index > 0) host.out.append(host.allocator, ' ') catch {};

        const value = quickjs.Value.fromCVal(raw);
        const text = value.toStringValue(ctx);
        defer text.deinit(ctx);

        if (text.toCString(ctx)) |cstr| {
            defer ctx.freeCString(cstr);
            host.out.appendSlice(host.allocator, std.mem.span(cstr)) catch {};
        }
    }

    host.out.append(host.allocator, '\n') catch {};
    return .undefined;
}
