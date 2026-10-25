const std = @import("std");

test {
    _ = @import("runtime_test.zig");
    _ = @import("timers_test.zig");
    _ = @import("promises_test.zig");
    _ = @import("fixtures_test.zig");
}
