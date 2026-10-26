const std = @import("std");
const cli = @import("cli/cli.zig");

pub const std_options: std.Options = .{ .log_level = .info };

pub fn main(init: std.process.Init) !void {
    cli.run(init) catch |err| {
        std.debug.print("jsz: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
