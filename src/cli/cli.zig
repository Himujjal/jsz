const std = @import("std");
const jsz = @import("jsz");

const usage =
    \\Usage: jsz [options] [script] [args...]
    \\
    \\Run a JavaScript file, evaluate an expression, or start the REPL.
    \\
    \\Options:
    \\  -e, --eval <code>   Evaluate code
    \\  --desktop           Run a main-process script with the native desktop backend
    \\  -h, --help          Show this help
    \\  -v, --version       Show version
    \\
    \\Commands:
    \\  repl                Start the REPL
    \\
;

pub fn run(init: std.process.Init) !u8 {
    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buffer);

    // A `jszc` binary carries its entry script in a trailer. It always runs
    // that script and forwards every argument to it, like a Node SEA
    // executable, so ordinary `jsz` flags are not interpreted.
    if (try jsz.sea.readSelf(init.gpa, init.io)) |payload| {
        defer payload.deinit(init.gpa);
        return runSea(init, &payload, &stdout.interface);
    }

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    const argv0 = args.next() orelse "jsz";

    var script: ?[]const u8 = null;
    var eval_source: ?[]const u8 = null;
    var desktop_mode = false;
    var script_args: std.ArrayList([]const u8) = .empty;
    defer script_args.deinit(init.gpa);

    while (args.next()) |arg| {
        if (script != null or eval_source != null) {
            try script_args.append(init.gpa, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try writeStdout(&stdout.interface, usage);
            return 0;
        }
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try writeStdout(&stdout.interface, "jsz " ++ jsz.version ++ "\n");
            return 0;
        }
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--eval")) {
            eval_source = args.next() orelse return error.MissingEvalSource;
            continue;
        }
        if (std.mem.eql(u8, arg, "--desktop")) {
            desktop_mode = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "repl")) continue;
        script = arg;
    }

    if (desktop_mode and (eval_source != null or script == null)) {
        return error.DesktopRequiresScript;
    }

    // Outlives the runtime: the host borrows this slice.
    var script_path: ?[]u8 = null;
    defer if (script_path) |path| init.gpa.free(path);
    if (script) |path| {
        const cwd = try std.process.currentPathAlloc(init.io, init.gpa);
        defer init.gpa.free(cwd);
        script_path = try std.fs.path.resolveAlloc(init.gpa, &.{ cwd, path });
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);

    try argv.append(init.gpa, argv0);
    if (script_path) |path| try argv.append(init.gpa, path);
    try argv.appendSlice(init.gpa, script_args.items);

    const runtime = try jsz.Runtime.init(init.gpa, .{
        .writer = &stdout.interface,
        .argv = argv.items,
        .environ_map = init.environ_map,
        .desktop = desktop_mode,
    });
    defer runtime.deinit();

    var code: u8 = 0;
    if (eval_source) |source| {
        code = try runSource(runtime, source, "<eval>");
    } else if (script_path) |path| {
        code = try runFile(runtime, path);
    } else {
        try runRepl(init, runtime, &stdout.interface);
    }
    try stdout.interface.flush();
    return code;
}

/// Runs the embedded entry point. Node SEA normalizes `argv[0]` to the
/// absolute executable path and keeps the invocation string at `argv[1]`,
/// which stands in for the missing script path.
fn runSea(
    init: std.process.Init,
    payload: *const jsz.sea.Payload,
    out: *std.Io.Writer,
) !u8 {
    const exe = try std.process.executablePathAlloc(init.io, init.gpa);
    defer init.gpa.free(exe);

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    const invocation = args.next() orelse exe;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);
    try argv.append(init.gpa, exe);
    try argv.append(init.gpa, invocation);
    while (args.next()) |arg| try argv.append(init.gpa, arg);

    const runtime = try jsz.Runtime.init(init.gpa, .{
        .writer = out,
        .argv = argv.items,
        .environ_map = init.environ_map,
        .desktop = payload.desktop,
        .assets = payload.assets,
        .is_sea = true,
    });
    defer runtime.deinit();

    const value = runtime.evalEntrySource(payload.source, exe, payload.name) catch |err| {
        try runtime.flush();
        return err;
    };
    value.deinit(runtime.context());
    try runtime.run();
    try out.flush();
    return runtime.exitCode();
}

fn runSource(runtime: *jsz.Runtime, source: []const u8, filename: [:0]const u8) !u8 {
    const value = runtime.evalDetected(source, filename) catch |err| {
        try runtime.flush();
        return err;
    };
    value.deinit(runtime.context());
    try runtime.run();
    return runtime.exitCode();
}

fn runFile(runtime: *jsz.Runtime, path: []const u8) !u8 {
    const value = runtime.evalFile(path) catch |err| {
        try runtime.flush();
        return err;
    };
    value.deinit(runtime.context());
    try runtime.run();
    return runtime.exitCode();
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
