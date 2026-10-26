const std = @import("std");
const quickjs = @import("quickjs");
const EventLoop = @import("../event_loop.zig").EventLoop;
const Fs = @import("../fs.zig").Fs;

pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ctx: *quickjs.Context,
    loop: *EventLoop,
    out: *std.ArrayList(u8),
    fs: *Fs,
    /// Borrowed process arguments; owned by the caller that outlives the runtime.
    argv: []const []const u8,
    environ: *std.process.Environ.Map,
};
