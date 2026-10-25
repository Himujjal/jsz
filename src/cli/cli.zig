const std = @import("std");
const jsz = @import("jsz");

const usage =
    \\Usage: jsz [options] [script]
    \\
    \\Run a JavaScript file, evaluate an expression, or start the REPL.
    \\
    \\Options:
    \\  -e, --eval <code>   Evaluate code
    \\  -h, --help          Show this help
    \\  -v, --version       Show version
    \\
    \\Commands:
    \\  repl                Start the REPL
    \\
;

pub fn run(init: std.process.Init) !void {
    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buffer);

    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.next();

    var script: ?[]const u8 = null;
    var eval_source: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try writeStdout(&stdout.interface, usage);
            return;
        }
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try writeStdout(&stdout.interface, "jsz " ++ jsz.version ++ "\n");
            return;
        }
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--eval")) {
            eval_source = args.next() orelse return error.MissingEvalSource;
            continue;
        }
        if (std.mem.eql(u8, arg, "repl")) continue;
        if (script == null) {
            script = arg;
            continue;
        }
        return error.UnexpectedArgument;
    }

    const runtime = try jsz.Runtime.init(init.gpa, .{ .writer = &stdout.interface });
    defer runtime.deinit();

    if (eval_source) |source| {
        try runSource(runtime, source, "<eval>");
    } else if (script) |path| {
        try runFile(runtime, path);
    } else {
        try runRepl(init, runtime, &stdout.interface);
    }
    try stdout.interface.flush();
}

fn runSource(runtime: *jsz.Runtime, source: []const u8, filename: [:0]const u8) !void {
    const value = runtime.eval(source, filename) catch |err| {
        try runtime.flush();
        return err;
    };
    value.deinit(runtime.context());
    try runtime.run();
}

fn runFile(runtime: *jsz.Runtime, path: []const u8) !void {
    const value = runtime.evalFile(path) catch |err| {
        try runtime.flush();
        return err;
    };
    value.deinit(runtime.context());
    try runtime.run();
}

fn runRepl(init: std.process.Init, runtime: *jsz.Runtime, out: *std.Io.Writer) !void {
    var read_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(init.io, &read_buffer);

    while (true) {
        try writeStdout(out, "jsz> ");

        // takeDelimiter returns null at EOF and consumes the delimiter.
        const maybe_line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.LineTooLong,
            error.ReadFailed => return error.ReadFailed,
        };
        const line = maybe_line orelse break;
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, ".exit")) break;

        const value = runtime.eval(line, "<repl>") catch {
            try runtime.flush();
            continue;
        };
        runtime.appendValue(value);
        value.deinit(runtime.context());

        runtime.tick() catch {
            try runtime.flush();
            continue;
        };
        try runtime.flush();
    }

    try writeStdout(out, "\n");
}

fn writeStdout(out: *std.Io.Writer, bytes: []const u8) !void {
    try out.writeAll(bytes);
    try out.flush();
}
