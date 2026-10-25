const std = @import("std");
const quickjs = @import("quickjs");
const EventLoop = @import("../event_loop.zig").EventLoop;

pub const Host = struct {
    allocator: std.mem.Allocator,
    ctx: *quickjs.Context,
    loop: *EventLoop,
    out: *std.ArrayList(u8),
};
