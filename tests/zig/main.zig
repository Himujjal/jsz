const std = @import("std");

pub const std_options: std.Options = .{
    .log_level = .info,
    // Dusty logs every listener at info; Node's `http` is quiet.
    .log_scope_levels = &.{.{ .scope = .dusty, .level = .warn }},
};

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
    _ = @import("net_test.zig");
    _ = @import("http_test.zig");
    _ = @import("fetch_test.zig");
    _ = @import("pkcs12_test.zig");
    _ = @import("differential_test.zig");
}
