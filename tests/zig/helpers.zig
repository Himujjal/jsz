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
