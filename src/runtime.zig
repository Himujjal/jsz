const std = @import("std");
const quickjs = @import("quickjs");
const zio = @import("zio");
const EventLoop = @import("event_loop.zig").EventLoop;
const Fs = @import("fs.zig").Fs;
const ChildProcesses = @import("child_process.zig").ChildProcesses;
const Net = @import("net.zig").Net;
const Http = @import("http.zig").Http;
const Fetch = @import("fetch.zig").Fetch;
const jobs = @import("jobs.zig");
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
    /// Shared completion queue: async subsystems report finished jobs here and
    /// the event loop settles them on the JS task.
    queue: jobs.Queue = undefined,
    fs: Fs = undefined,
    children: ChildProcesses = undefined,
    net: Net = undefined,
    http: Http = undefined,
    fetch: Fetch = undefined,
    host: Host = undefined,
    out: std.ArrayList(u8) = .empty,
    writer: ?*std.Io.Writer = null,
    env_owned: ?std.process.Environ.Map = null,
    entry_owned: ?[]u8 = null,
    sigint_handle: ?zio.JoinHandle(void) = null,
    shutdown_done: bool = false,
    had_error: bool = false,

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

        self.queue = jobs.Queue.init(allocator);
        errdefer self.queue.deinit();

        self.fs = Fs.init(allocator, zio_rt, &self.queue);
        self.children = ChildProcesses.init(allocator, zio_rt, &self.queue);
        self.net = Net.init(allocator, zio_rt, &self.queue);
        self.http = Http.init(allocator, zio_rt, &self.queue);
        self.fetch = Fetch.init(allocator, zio_rt, &self.queue);
        self.loop.queue = &self.queue;

        self.env_owned = if (options.environ_map == null) std.process.Environ.Map.init(allocator) else null;
        errdefer if (self.env_owned) |*map| map.deinit();

        self.host = .{
            .allocator = allocator,
            .io = zio_rt.io(),
            .ctx = ctx,
            .loop = &self.loop,
            .out = &self.out,
            .fs = &self.fs,
            .rt = zio_rt,
            .children = &self.children,
            .net = &self.net,
            .http = &self.http,
            .fetch = &self.fetch,
            .argv = options.argv orelse &.{},
            .environ = options.environ_map orelse &self.env_owned.?,
        };
        ctx.setOpaque(Host, &self.host);
        self.host.refreshCwd();
        errdefer self.host.deinitCwd();
        try builtins.register(&self.host);
        js_rt.setModuleLoaderFunc(Host, &self.host, module.normalize, module.load);
        js_rt.setHostPromiseRejectionTracker(Host, &self.host, onPromiseRejection);

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
        self.stopSigintWatcher();
        self.finish();
        self.flush() catch {};
        self.host.deinitCwd();
        // Live children must be reaped while QuickJS and the queue still exist.
        self.children.deinit(self.ctx);
        // Network handles must stop before the queue closes.
        self.fetch.deinit(self.ctx);
        self.http.deinit(self.ctx);
        self.net.deinit(self.ctx);
        // QuickJS must still be alive for abort callbacks.
        self.queue.shutdown(self.ctx);
        self.queue.deinit();
        self.loop.deinit();
        self.ctx.deinit();
        self.js_rt.deinit();
        self.zio_rt.deinit();
        if (self.env_owned) |*map| map.deinit();
        if (self.entry_owned) |entry| self.allocator.free(entry);
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

    /// Re-reads the process cwd into `host.cwd`; on failure it is unchanged.
    pub fn refreshCwd(self: *Runtime) void {
        self.host.refreshCwd();
    }

    pub fn eval(
        self: *Runtime,
        source: []const u8,
        filename: [:0]const u8,
    ) !quickjs.Value {
        // QuickJS requires input[input_len] to be a NUL byte.
        const terminated = try self.allocator.dupeSentinel(u8, source, 0);
        defer self.allocator.free(terminated);
        self.host.entry = null;
        return self.evalTerminated(terminated, filename, false);
    }

    /// Evaluates `source` as a module when it uses top-level import/export
    /// syntax, matching Node's `--input-type=detect` for `-e`.
    pub fn evalDetected(
        self: *Runtime,
        source: []const u8,
        filename: [:0]const u8,
    ) !quickjs.Value {
        const terminated = try self.allocator.dupeSentinel(u8, source, 0);
        defer self.allocator.free(terminated);
        self.host.entry = null;
        return self.evalTerminated(terminated, filename, quickjs.detectModule(source));
    }

    pub fn evalFile(self: *Runtime, path: []const u8) !quickjs.Value {
        // The loader canonicalizes file modules to absolute paths, so the entry
        // must use the same form for `import.meta.main` and `import.meta.url`
        // to match. `resolveAlloc` alone does not prepend the cwd.
        const entry = if (std.fs.path.isAbsolute(path))
            try std.fs.path.resolveAlloc(self.allocator, &.{path})
        else blk: {
            const cwd = try std.process.currentPathAlloc(self.zio_rt.io(), self.allocator);
            defer self.allocator.free(cwd);
            break :blk try std.fs.path.resolveAlloc(self.allocator, &.{ cwd, path });
        };
        if (self.entry_owned) |previous| self.allocator.free(previous);
        self.entry_owned = entry;
        self.host.entry = self.entry_owned.?;

        const source = try std.Io.Dir.cwd().readFileAllocOptions(
            self.zio_rt.io(),
            entry,
            self.allocator,
            .limited(16 * 1024 * 1024),
            .of(u8),
            0,
        );
        defer self.allocator.free(source);

        const filename = try self.allocator.dupeSentinel(u8, entry, 0);
        defer self.allocator.free(filename);

        return self.evalTerminated(source, filename, isModulePath(entry, source));
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
        if (!is_module) {
            const value = self.ctx.eval(source, filename, .{});
            if (value.isException()) {
                value.deinit(self.ctx);
                return self.failEval();
            }
            return value;
        }

        // The entry never passes through the loader, so compile it here to set
        // its `import.meta` before QuickJS instantiates and evaluates it.
        const compiled = self.ctx.eval(source, filename, .{ .type = .module, .compile_only = true });
        if (compiled.isException()) {
            compiled.deinit(self.ctx);
            return self.failEval();
        }
        const def = module.moduleDefFromValue(compiled) orelse {
            _ = self.ctx.throwInternalError("module compilation produced no module definition");
            self.reportException();
            compiled.deinit(self.ctx);
            self.had_error = true;
            return error.ModuleInitFailed;
        };
        module.setImportMeta(&self.host, self.ctx, def, filename, true);

        // JS_EvalFunction takes ownership of the compiled value.
        const value = self.ctx.evalFunction(compiled);
        if (value.isException()) {
            value.deinit(self.ctx);
            return self.failEval();
        }
        if (!value.isPromise()) return value;
        if (value.promiseState(self.ctx) != .rejected) return value;

        // Module evaluation reports a top-level throw by rejecting the
        // returned promise instead of raising a context exception.
        defer value.deinit(self.ctx);
        const reason = value.promiseResult(self.ctx);
        defer reason.deinit(self.ctx);
        self.loop.discardRejectionsFor(reason);
        if (self.loop.handleUncaughtValue(reason)) return .undefined;
        self.had_error = true;
        return error.JavaScriptError;
    }

    /// Routes an eval-time exception through `uncaughtException` when a
    /// listener is installed; the script still stops, like Node.
    fn failEval(self: *Runtime) !quickjs.Value {
        if (self.loop.handleUncaught()) return .undefined;
        self.had_error = true;
        return error.JavaScriptError;
    }

    pub fn run(self: *Runtime) !void {
        if (self.loop.sigint_wanted and self.sigint_handle == null) {
            self.sigint_handle = try self.zio_rt.spawn(waitForSigint, .{&self.loop});
        }

        const result = self.loop.run();
        self.stopSigintWatcher();
        if (result) |_| {} else |_| self.had_error = true;
        self.finish();
        try self.flush();
        return result;
    }

    fn stopSigintWatcher(self: *Runtime) void {
        if (self.sigint_handle) |*handle| {
            handle.cancel();
            self.sigint_handle = null;
        }
    }

    /// Shutdown ordering: exit hooks, then unhandled rejections, then the
    /// caller flushes and deinits.
    fn finish(self: *Runtime) void {
        if (self.shutdown_done) return;
        self.shutdown_done = true;

        const code: u8 = if (self.had_error or self.loop.failed) 1 else self.loop.exit_code;
        self.loop.runExitHooks(code);
        self.loop.reportUnhandledRejections();
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

/// Runs on a zio task; it only sets a flag and wakes the queue, never touches
/// QuickJS.
fn waitForSigint(loop: *EventLoop) void {
    var signal = zio.Signal.init(.interrupt) catch return;
    defer signal.deinit();

    while (true) {
        signal.wait() catch return;
        loop.interrupt();
    }
}

fn onPromiseRejection(
    host_opt: ?*Host,
    _: *quickjs.Context,
    promise: quickjs.Value,
    reason: quickjs.Value,
    is_handled: bool,
) void {
    const host = host_opt orelse return;
    host.loop.trackRejection(promise, reason, is_handled);
}
