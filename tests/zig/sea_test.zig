const std = @import("std");
const options = @import("test_options");

fn expectExit(result: std.process.RunResult, expected: u8) !void {
    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(expected, code),
        else => return error.UnexpectedTerm,
    }
}

fn tempPaths(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
) !struct { dir: []u8, abs: []u8 } {
    const dir = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &tmp.sub_path });
    errdefer allocator.free(dir);
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const abs = try std.fs.path.resolveAlloc(allocator, &.{ cwd, dir });
    return .{ .dir = dir, .abs = abs };
}

test "jszc embeds the entry script and forwards arguments" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "tests/fixtures/sea/main.mjs",
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(source);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.mjs", .data = source });

    const paths = try tempPaths(allocator, &tmp);
    defer allocator.free(paths.dir);
    defer allocator.free(paths.abs);

    const script = try std.fs.path.join(allocator, &.{ paths.abs, "main.mjs" });
    defer allocator.free(script);
    const output = try std.fs.path.join(allocator, &.{ paths.abs, "app" });
    defer allocator.free(output);

    const compiled = try std.process.run(allocator, io, .{
        .argv = &.{ options.jszc_exe, script, "-o", output },
    });
    defer allocator.free(compiled.stdout);
    defer allocator.free(compiled.stderr);
    try expectExit(compiled, 0);

    // Compilation must capture the source; the executable may not read it.
    try tmp.dir.deleteFile(io, "main.mjs");

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ output, "alpha", "beta" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try expectExit(result, 0);

    const expected = try std.mem.concat(allocator, u8, &.{
        "name=app\nargv0=",
        output,
        "\nargv1=",
        output,
        "\nargs=alpha,beta\nmain=true\nurl=file://",
        output,
        "\n",
    });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result.stdout);

    // Node SEA keeps the invocation string at argv[1] and normalizes argv[0]
    // to the absolute executable path.
    const relative = try std.process.run(allocator, io, .{
        .argv = &.{ "./app", "rel" },
        .cwd = .{ .path = paths.abs },
    });
    defer allocator.free(relative.stdout);
    defer allocator.free(relative.stderr);
    try expectExit(relative, 0);

    const expected_relative = try std.mem.concat(allocator, u8, &.{
        "name=app\nargv0=",
        output,
        "\nargv1=./app\nargs=rel\nmain=true\nurl=file://",
        output,
        "\n",
    });
    defer allocator.free(expected_relative);
    try std.testing.expectEqualStrings(expected_relative, relative.stdout);
}

test "jszc writes a JSON-configured output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try tempPaths(allocator, &tmp);
    defer allocator.free(paths.dir);
    defer allocator.free(paths.abs);

    const config = try std.fmt.allocPrint(
        allocator,
        "{{\"main\": \"{s}/main.js\", \"output\": \"{s}/configured\"}}\n",
        .{ paths.abs, paths.abs },
    );
    defer allocator.free(config);

    try tmp.dir.writeFile(io, .{
        .sub_path = "main.js",
        .data = "console.log(\"configured=ok\");\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "sea.json", .data = config });

    const config_path = try std.fs.path.join(allocator, &.{ paths.abs, "sea.json" });
    defer allocator.free(config_path);
    const output = try std.fs.path.join(allocator, &.{ paths.abs, "configured" });
    defer allocator.free(output);

    const compiled = try std.process.run(allocator, io, .{
        .argv = &.{ options.jszc_exe, "--config", config_path },
    });
    defer allocator.free(compiled.stdout);
    defer allocator.free(compiled.stderr);
    try expectExit(compiled, 0);

    const result = try std.process.run(allocator, io, .{ .argv = &.{output} });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try expectExit(result, 0);
    try std.testing.expectEqualStrings("configured=ok\n", result.stdout);
}

test "jszc rejects an output that would overwrite the input" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try tempPaths(allocator, &tmp);
    defer allocator.free(paths.dir);
    defer allocator.free(paths.abs);

    const script = try std.fs.path.join(allocator, &.{ paths.abs, "same.js" });
    defer allocator.free(script);
    try tmp.dir.writeFile(io, .{ .sub_path = "same.js", .data = "1;\n" });

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ options.jszc_exe, script, "-o", script },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 1), code),
        else => return error.UnexpectedTerm,
    }
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "OutputWouldOverwriteInput") != null);
}

test "jszc embeds assets and exposes node:sea" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try tempPaths(allocator, &tmp);
    defer allocator.free(paths.dir);
    defer allocator.free(paths.abs);

    try tmp.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hello asset\n" });
    const nested = try std.fs.path.join(allocator, &.{ paths.abs, "nested" });
    defer allocator.free(nested);
    try std.Io.Dir.cwd().createDirPath(io, nested);
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/data.bin", .data = "\x01\x02\x03" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.mjs", .data =
        \\import * as sea from "node:sea";
        \\console.log("issea=" + sea.isSea());
        \\console.log("keys=" + sea.getAssetKeys().sort().join(","));
        \\console.log("txt=" + sea.getAsset("hello.txt", "utf-8").trim());
        \\console.log("nested=" + Buffer.from(sea.getRawAsset("nested/data.bin")).length);
        \\
    });

    const config = try std.fmt.allocPrint(
        allocator,
        "{{\"main\": \"{s}/main.mjs\", \"output\": \"{s}/app\", \"assets\": " ++
            "{{\"hello.txt\": \"{s}/hello.txt\", \"nested/data.bin\": \"{s}/nested/data.bin\"}}}}\n",
        .{ paths.abs, paths.abs, paths.abs, paths.abs },
    );
    defer allocator.free(config);
    try tmp.dir.writeFile(io, .{ .sub_path = "sea.json", .data = config });

    const config_path = try std.fs.path.join(allocator, &.{ paths.abs, "sea.json" });
    defer allocator.free(config_path);
    const output = try std.fs.path.join(allocator, &.{ paths.abs, "app" });
    defer allocator.free(output);

    const compiled = try std.process.run(allocator, io, .{
        .argv = &.{ options.jszc_exe, "--config", config_path },
    });
    defer allocator.free(compiled.stdout);
    defer allocator.free(compiled.stderr);
    try expectExit(compiled, 0);

    const result = try std.process.run(allocator, io, .{ .argv = &.{output} });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try expectExit(result, 0);
    try std.testing.expectEqualStrings(
        "issea=true\nkeys=hello.txt,nested/data.bin\ntxt=hello asset\nnested=3\n",
        result.stdout,
    );
}

test "jszc enables desktop mode from the config" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try tempPaths(allocator, &tmp);
    defer allocator.free(paths.dir);
    defer allocator.free(paths.abs);

    try tmp.dir.writeFile(io, .{ .sub_path = "main.mjs", .data =
        \\import { app } from "electron";
        \\console.log("desktop=" + (typeof app.getVersion() === "string"));
        \\
    });

    const config = try std.fmt.allocPrint(
        allocator,
        "{{\"main\": \"{s}/main.mjs\", \"output\": \"{s}/app\", \"desktop\": true}}\n",
        .{ paths.abs, paths.abs },
    );
    defer allocator.free(config);
    try tmp.dir.writeFile(io, .{ .sub_path = "sea.json", .data = config });

    const config_path = try std.fs.path.join(allocator, &.{ paths.abs, "sea.json" });
    defer allocator.free(config_path);
    const output = try std.fs.path.join(allocator, &.{ paths.abs, "app" });
    defer allocator.free(output);

    const compiled = try std.process.run(allocator, io, .{
        .argv = &.{ options.jszc_exe, "--config", config_path },
    });
    defer allocator.free(compiled.stdout);
    defer allocator.free(compiled.stderr);
    try expectExit(compiled, 0);

    const result = try std.process.run(allocator, io, .{ .argv = &.{output} });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try expectExit(result, 0);
    try std.testing.expectEqualStrings("desktop=true\n", result.stdout);
}

test "jszc desktop app loads preload and html from assets" {
    if (std.c.getenv("JSZ_DESKTOP_TESTS") == null) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const paths = try tempPaths(allocator, &tmp);
    defer allocator.free(paths.dir);
    defer allocator.free(paths.abs);

    const config = try std.fmt.allocPrint(
        allocator,
        "{{\"main\": \"tests/fixtures/electron/main.mjs\", " ++
            "\"output\": \"{s}/app\", \"desktop\": true, \"assets\": " ++
            "{{\"preload.mjs\": \"tests/fixtures/electron/preload.mjs\", " ++
            "\"index.html\": \"tests/fixtures/electron/index.html\"}}}}\n",
        .{paths.abs},
    );
    defer allocator.free(config);
    try tmp.dir.writeFile(io, .{ .sub_path = "sea.json", .data = config });

    const config_path = try std.fs.path.join(allocator, &.{ paths.abs, "sea.json" });
    defer allocator.free(config_path);
    const output = try std.fs.path.join(allocator, &.{ paths.abs, "app" });
    defer allocator.free(output);

    const compiled = try std.process.run(allocator, io, .{
        .argv = &.{ options.jszc_exe, "--config", config_path },
    });
    defer allocator.free(compiled.stdout);
    defer allocator.free(compiled.stderr);
    try expectExit(compiled, 0);

    const result = try std.process.run(allocator, io, .{ .argv = &.{output} });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try expectExit(result, 0);
    try std.testing.expectEqualStrings("desktop=ok:hello:true\n", result.stdout);
}
