const quickjs = @import("quickjs");
const Host = @import("host.zig").Host;
const timers = @import("timers.zig");
const promises = @import("promises.zig");
const console = @import("console.zig");

pub fn register(host: *Host) !void {
    const ctx = host.ctx;
    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    try global.setPropertyStr(ctx, "setTimeout", .initCFunction(ctx, timers.setTimeout, "setTimeout", 2));
    try global.setPropertyStr(ctx, "clearTimeout", .initCFunction(ctx, timers.clearTimeout, "clearTimeout", 1));
    try global.setPropertyStr(ctx, "setInterval", .initCFunction(ctx, timers.setInterval, "setInterval", 2));
    try global.setPropertyStr(ctx, "clearInterval", .initCFunction(ctx, timers.clearInterval, "clearInterval", 1));
    try global.setPropertyStr(ctx, "sleep", .initCFunction(ctx, promises.sleep, "sleep", 1));

    const console_object = quickjs.Value.initObject(ctx);
    defer console_object.deinit(ctx);

    try console_object.setPropertyStr(ctx, "log", .initCFunction(ctx, console.log, "log", 1));
    try console_object.setPropertyStr(ctx, "error", .initCFunction(ctx, console.writeError, "error", 1));

    try global.setPropertyStr(ctx, "console", console_object.dup(ctx));
}
