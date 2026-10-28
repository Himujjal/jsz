const std = @import("std");

pub const std_options: std.Options = .{ .log_level = .info };

test {
    _ = @import("runtime_test.zig");
    _ = @import("timers_test.zig");
    _ = @import("promises_test.zig");
    _ = @import("fixtures_test.zig");
    _ = @import("path_test.zig");
    _ = @import("fs_test.zig");
    _ = @import("process_test.zig");
    _ = @import("cli_test.zig");
    _ = @import("module_test.zig");
    _ = @import("buffer_test.zig");
    _ = @import("jobs_test.zig");
    _ = @import("async_test.zig");
    _ = @import("os_test.zig");
    _ = @import("crypto_test.zig");
    _ = @import("url_test.zig");
    _ = @import("util_test.zig");
    _ = @import("events_test.zig");
    _ = @import("child_process_test.zig");
}
