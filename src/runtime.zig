const std = @import("std");
const quickjs = @import("quickjs");
const zio = @import("zio");
const EventLoop = @import("event_loop.zig").EventLoop;
const Fs = @import("fs.zig").Fs;
const Host = @import("js/host.zig").Host;
const builtins = @import("js/builtins.zig");
const module = @import("module.zig");

pub const Options = struct {
    max_runtime_ms: ?u64 = null,
    max_iterations: ?usize = null,
    writer: ?*std.Io.Writer = null,
    /// Borrowed process arguments; the caller must outlive the runtime.
    argv: ?[]const []const u8 = null,
    environ_map: ?*std.process.Environ.Map = null,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    zio_rt: *zio.Runtime,
    js_rt: *quickjs.Runtime,
    ctx: *quickjs.Context,
    loop: EventLoop,
    fs: Fs = undefined,
    host: Host = undefined,
    out: std.ArrayList(u8) = .empty,
    writer: ?*std.Io.Writer = null,
    env_owned: ?std.process.Environ.Map = null,

    pub fn init(allocator: std.mem.Allocator, options: Options) !*Runtime {
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);

        const zio_rt = try zio.Runtime.init(allocator, .{
            .executors = .exact(1),
            .enable_main_executor = false,
        });
        errdefer zio_rt.deinit();

        const js_rt = try quickjs.Runtime.init();
        errdefer js_rt.deinit();

        const ctx = try quickjs.Context.init(js_rt);
        errdefer ctx.deinit();

        self.* = .{
            .allocator = allocator,
            .zio_rt = zio_rt,
            .js_rt = js_rt,
            .ctx = ctx,
            .loop = undefined,
            .writer = options.writer,
        };
        errdefer self.out.deinit(allocator);

        self.loop = try EventLoop.init(allocator, ctx, js_rt);
        errdefer self.loop.deinit();
        self.loop.sink = &self.out;
        self.loop.max_iterations = options.max_iterations;
        self.loop.max_runtime_ns = if (options.max_runtime_ms) |ms| ms *| std.time.ns_per_ms else null;

        self.fs = Fs.init(allocator, zio_rt);
        self.loop.fs = &self.fs;

        self.env_owned = if (options.environ_map == null) std.process.Environ.Map.init(allocator) else null;
        errdefer if (self.env_owned) |*map| map.deinit();

        self.host = .{
            .allocator = allocator,
            .io = zio_rt.io(),
            .ctx = ctx,
            .loop = &self.loop,
            .out = &self.out,
            .fs = &self.fs,
            .argv = options.argv orelse &.{},
            .environ = options.environ_map orelse &self.env_owned.?,
        };
        ctx.setOpaque(Host, &self.host);
        try builtins.register(&self.host);
        js_rt.setModuleLoaderFunc(Host, &self.host, module.normalize, module.load);

        // Bootstrap last: it imports the modules that need the host opaque set.
        const bootstrap = @embedFile("builtins/bootstrap.js");
        const value = ctx.eval(bootstrap, "jsz:bootstrap", .{ .type = .module });
        if (value.isException()) {
            value.deinit(ctx);
            return error.ModuleInitFailed;
        }
        value.deinit(ctx);

        return self;
    }

    pub fn deinit(self: *Runtime) void {
        self.flush() catch {};
        self.fs.deinit(self.ctx);
        self.loop.deinit();
        self.ctx.deinit();
        self.js_rt.deinit();
        self.zio_rt.deinit();
        if (self.env_owned) |*map| map.deinit();
        self.out.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn exitCode(self: *Runtime) u8 {
        return self.loop.exit_code;
    }

    pub fn context(self: *Runtime) *quickjs.Context {
        return self.ctx;
    }

    pub fn eval(
        self: *Runtime,
        source: []const u8,
        filename: [:0]const u8,
    ) !quickjs.Value {
        // QuickJS requires input[input_len] to be a NUL byte.
        const terminated = try self.allocator.dupeSentinel(u8, source, 0);
        defer self.allocator.free(terminated);
        return self.evalTerminated(terminated, filename, false);
    }

    pub fn evalFile(self: *Runtime, path: []const u8) !quickjs.Value {
        const source = try std.Io.Dir.cwd().readFileAllocOptions(
            self.zio_rt.io(),
            path,
            self.allocator,
            .limited(16 * 1024 * 1024),
            .of(u8),
            0,
        );
        defer self.allocator.free(source);

        const filename = try self.allocator.dupeSentinel(u8, path, 0);
        defer self.allocator.free(filename);

        return self.evalTerminated(source, filename, isModulePath(path, source));
    }

    /// `.mjs` is always a module, `.cjs` is always a script, and `.js` is
    /// detected from its top-level syntax (Node does the same for
    /// ambiguous input).
    fn isModulePath(path: []const u8, source: []const u8) bool {
        if (std.mem.endsWith(u8, path, ".mjs")) return true;
        if (std.mem.endsWith(u8, path, ".cjs")) return false;
        return quickjs.detectModule(source);
    }

    fn evalTerminated(
        self: *Runtime,
        source: [:0]const u8,
        filename: [:0]const u8,
        is_module: bool,
    ) !quickjs.Value {
        const flags: quickjs.EvalFlags = if (is_module) .{ .type = .module } else .{};
        const value = self.ctx.eval(source, filename, flags);
        if (value.isException()) {
            self.reportException();
            value.deinit(self.ctx);
            return error.JavaScriptError;
        }
        return value;
    }

    pub fn run(self: *Runtime) !void {
        try self.loop.run();
        try self.flush();
    }

    pub fn tick(self: *Runtime) !void {
        try self.loop.tick();
        try self.flush();
    }

    pub fn appendValue(self: *Runtime, value: quickjs.Value) void {
        const text = value.toStringValue(self.ctx);
        defer text.deinit(self.ctx);

        if (text.toCString(self.ctx)) |cstr| {
            defer self.ctx.freeCString(cstr);
            self.out.appendSlice(self.allocator, std.mem.span(cstr)) catch {};
        }
        self.out.append(self.allocator, '\n') catch {};
    }

    pub fn flush(self: *Runtime) !void {
        if (self.out.items.len == 0) return;

        if (self.writer) |writer| {
            try writer.writeAll(self.out.items);
            try writer.flush();
        } else {
            var buffer: [4096]u8 = undefined;
            var writer = std.Io.File.stdout().writer(self.zio_rt.io(), &buffer);
            try writer.interface.writeAll(self.out.items);
            try writer.interface.flush();
        }

        self.out.clearRetainingCapacity();
    }

    fn reportException(self: *Runtime) void {
        self.loop.reportException();
    }
};
