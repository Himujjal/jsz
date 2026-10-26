const std = @import("std");
const jsz = @import("jsz");

pub const fixture_dir = @import("test_options").fixtures_dir;

pub fn initRuntime(writer: ?*std.Io.Writer) !*jsz.Runtime {
    return jsz.Runtime.init(std.testing.allocator, .{
        .writer = writer,
        .max_iterations = 10_000,
        .max_runtime_ms = 5_000,
    });
}

pub fn readResult(allocator: std.mem.Allocator, runtime: *jsz.Runtime) ![]u8 {
    const value = try runtime.eval("globalThis.__result", "<result>");
    defer value.deinit(runtime.context());

    const cstr = value.toCString(runtime.context()) orelse return error.MissingResult;
    defer runtime.context().freeCString(cstr);
    return allocator.dupe(u8, std.mem.span(cstr));
}

pub const ProcessOptions = struct {
    /// Full argv, including argv[0]. Defaults to `{"jsz", <absolute fixture>}`.
    argv: ?[]const []const u8 = null,
    env: []const [2][]const u8 = &.{},
};

pub const ProcessResult = struct {
    stdout: []u8,
    exit_code: u8,

    pub fn deinit(self: ProcessResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
    }
};

/// Runs a fixture with an explicit `process.argv` and environment, and reports
/// the exit code set by `process.exit`.
pub fn runFixtureProcess(
    allocator: std.mem.Allocator,
    name: []const u8,
    options: ProcessOptions,
) !ProcessResult {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    for (options.env) |pair| try env.put(pair[0], pair[1]);

    const path = try std.fs.path.resolveAlloc(allocator, &.{ fixture_dir, name });
    defer allocator.free(path);

    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);

    const argv: []const []const u8 = options.argv orelse blk: {
        try argv_list.append(allocator, "jsz");
        try argv_list.append(allocator, path);
        break :blk argv_list.items;
    };

    const runtime = try jsz.Runtime.init(allocator, .{
        .writer = &writer.writer,
        .max_iterations = 10_000,
        .max_runtime_ms = 5_000,
        .argv = argv,
        .environ_map = &env,
    });
    defer runtime.deinit();

    const value = try runtime.evalFile(path);
    value.deinit(runtime.context());
    try runtime.run();

    return .{
        .stdout = try allocator.dupe(u8, writer.written()),
        .exit_code = runtime.exitCode(),
    };
}

pub fn runFixture(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    const runtime = try initRuntime(&writer.writer);
    defer runtime.deinit();

    const path = try std.fs.path.join(allocator, &.{ fixture_dir, name });
    defer allocator.free(path);

    const value = try runtime.evalFile(path);
    value.deinit(runtime.context());
    try runtime.run();

    return readResult(allocator, runtime);
}

/// Runs a fixture and returns everything it wrote through `console.log`.
pub fn runFixtureStdout(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    const runtime = try initRuntime(&writer.writer);
    defer runtime.deinit();

    const path = try std.fs.path.join(allocator, &.{ fixture_dir, name });
    defer allocator.free(path);

    const value = try runtime.evalFile(path);
    value.deinit(runtime.context());
    try runtime.run();
    try runtime.flush();

    return allocator.dupe(u8, writer.written());
}
