//! `jszc` turns a JavaScript entry point into a standalone executable by
//! copying a `jsz` runtime binary and appending the script payload. The runtime
//! already knows how to read that payload, so the produced file depends on
//! nothing else at run time.

const std = @import("std");
const jsz = @import("jsz");
const sea = jsz.sea;

const embedded_runtime: []const u8 = @import("runtime_embed").bytes;

const usage =
    \\Usage: jszc [options] <script>
    \\
    \\Compile a JavaScript entry point into a standalone executable that
    \\embeds the jsz runtime and the script.
    \\
    \\Options:
    \\  -o, --output <path>   Output path (default: script name without extension)
    \\  --config <path>       Read "main", "output", "assets", and "desktop" from JSON
    \\  --jsz <path>          Use a specific jsz binary instead of the embedded one
    \\  --name <name>         Logical name recorded in the payload
    \\  --desktop             Enable the Electron-shaped desktop backend
    \\  -h, --help            Show this help
    \\  -v, --version         Show version
    \\
;

pub fn main(init: std.process.Init) !void {
    const code = run(init) catch |err| {
        var buffer: [4096]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(init.io, &buffer);
        stderr.interface.print("jszc: {s}\n", .{@errorName(err)}) catch {};
        stderr.interface.flush() catch {};
        std.process.exit(1);
    };
    if (code != 0) std.process.exit(code);
}

fn run(init: std.process.Init) !u8 {
    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buffer);

    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.next();

    var entry: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var runtime_path: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var config_path: ?[]const u8 = null;
    var desktop = false;

    while (args.next()) |arg| {
        if (is(arg, "-h") or is(arg, "--help")) {
            try writeStdout(&stdout.interface, usage);
            return 0;
        }
        if (is(arg, "-v") or is(arg, "--version")) {
            try stdout.interface.print("jszc {s}\n", .{jsz.version});
            try stdout.interface.flush();
            return 0;
        }
        if (is(arg, "--desktop")) {
            desktop = true;
            continue;
        }
        if (is(arg, "-o") or is(arg, "--output")) {
            output = args.next() orelse return error.MissingOutput;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--output=")) {
            output = arg["--output=".len..];
            continue;
        }
        if (is(arg, "--config")) {
            config_path = args.next() orelse return error.MissingConfig;
            continue;
        }
        if (is(arg, "--jsz")) {
            runtime_path = args.next() orelse return error.MissingRuntime;
            continue;
        }
        if (is(arg, "--name")) {
            name = args.next() orelse return error.MissingName;
            continue;
        }
        if (arg.len > 1 and arg[0] == '-') return error.UnknownOption;
        if (entry != null) return error.TooManyInputs;
        entry = arg;
    }

    var config: ?std.json.Parsed(std.json.Value) = null;
    defer if (config) |*parsed| parsed.deinit();
    var asset_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer asset_arena.deinit();
    var assets: std.ArrayList(sea.Asset) = .empty;
    if (config_path) |path| {
        const data = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            path,
            init.gpa,
            .limited(1024 * 1024),
        );
        defer init.gpa.free(data);

        config = try std.json.parseFromSlice(std.json.Value, init.gpa, data, .{});
        const object = switch (config.?.value) {
            .object => |object| object,
            else => return error.InvalidConfig,
        };
        if (object.get("main")) |value| {
            const main_path = switch (value) {
                .string => |text| text,
                else => return error.InvalidConfig,
            };
            if (entry == null) entry = main_path;
        }
        if (object.get("output")) |value| {
            const output_path = switch (value) {
                .string => |text| text,
                else => return error.InvalidConfig,
            };
            if (output == null) output = output_path;
        }
        if (object.get("desktop")) |value| {
            const enabled = switch (value) {
                .bool => |enabled| enabled,
                else => return error.InvalidConfig,
            };
            // `--desktop` is explicit; the config can only add the mode.
            desktop = desktop or enabled;
        }
        if (object.get("assets")) |value| {
            const map = switch (value) {
                .object => |map| map,
                else => return error.InvalidConfig,
            };
            const allocator = asset_arena.allocator();
            var iterator = map.iterator();
            while (iterator.next()) |asset_entry| {
                const key = sea.cleanKey(asset_entry.key_ptr.*) orelse return error.InvalidAssetKey;
                const asset_path = switch (asset_entry.value_ptr.*) {
                    .string => |text| text,
                    else => return error.InvalidConfig,
                };
                const asset_data = try std.Io.Dir.cwd().readFileAlloc(
                    init.io,
                    asset_path,
                    allocator,
                    .limited(sea.max_payload_bytes),
                );
                try assets.append(allocator, .{
                    .key = try allocator.dupe(u8, key),
                    .data = asset_data,
                });
            }
        }
    }

    const entry_path = entry orelse {
        try writeStdout(&stdout.interface, usage);
        return 2;
    };
    const source_name = name orelse std.fs.path.basename(entry_path);
    const output_path = output orelse std.fs.path.stem(std.fs.path.basename(entry_path));

    const source = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        entry_path,
        init.gpa,
        .limited(sea.max_payload_bytes),
    );
    defer init.gpa.free(source);

    try ensureDifferent(init.gpa, entry_path, output_path);
    if (runtime_path) |path| try ensureDifferent(init.gpa, path, output_path);

    const payload = try sea.buildPayload(init.gpa, .{
        .name = source_name,
        .source = source,
        .assets = assets.items,
        .desktop = desktop,
    });
    defer init.gpa.free(payload);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const footer = sea.encodeFooter(.{ .payload_len = payload.len, .digest = digest });

    var runtime_owned: ?[]u8 = null;
    defer if (runtime_owned) |bytes| init.gpa.free(bytes);
    const runtime: []const u8 = if (runtime_path) |path| blk: {
        runtime_owned = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            path,
            init.gpa,
            .limited(512 * 1024 * 1024),
        );
        break :blk runtime_owned.?;
    } else embedded_runtime;

    const permissions: std.Io.File.Permissions = if (comptime std.Io.File.Permissions.has_executable_bit)
        .fromMode(0o755)
    else
        .default_file;

    var file = try std.Io.Dir.cwd().createFile(init.io, output_path, .{
        .truncate = true,
        .permissions = permissions,
    });
    defer file.close(init.io);

    try file.writeStreamingAll(init.io, runtime);
    try file.writeStreamingAll(init.io, payload);
    try file.writeStreamingAll(init.io, &footer);
    if (comptime std.Io.File.Permissions.has_executable_bit) {
        try file.setPermissions(init.io, permissions);
    }

    try stdout.interface.print("jszc: wrote {s}\n", .{output_path});
    try stdout.interface.flush();
    return 0;
}

fn ensureDifferent(
    allocator: std.mem.Allocator,
    input: []const u8,
    output: []const u8,
) !void {
    const abs_input = try std.fs.path.resolveAlloc(allocator, &.{input});
    defer allocator.free(abs_input);
    const abs_output = try std.fs.path.resolveAlloc(allocator, &.{output});
    defer allocator.free(abs_output);
    if (std.mem.eql(u8, abs_input, abs_output)) return error.OutputWouldOverwriteInput;
}

fn is(arg: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, arg, expected);
}

fn writeStdout(out: *std.Io.Writer, bytes: []const u8) !void {
    try out.writeAll(bytes);
    try out.flush();
}
