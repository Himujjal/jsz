//! Opt-in desktop backend for the Electron-shaped `electron` builtin.
//!
//! The native window is an embedded OS WebView (WKWebView, WebView2, or
//! WebKitGTK via WebUI), never a bundled Chromium. All QuickJS calls stay on
//! the JS task; WebUI callbacks copy their arguments into a queue and wake the
//! event loop, which dispatches them on the JS task.

const std = @import("std");
const quickjs = @import("quickjs");
const webui = @import("webui");
const zio = @import("zio");
const jobs = @import("jobs.zig");
const module = @import("module.zig");
const EventLoop = @import("event_loop.zig").EventLoop;
const Host = @import("js/host.zig").Host;

const Value = quickjs.Value;
const c = quickjs.c;

const max_module_bytes = 16 * 1024 * 1024;
const max_bridge_payload = 4 * 1024 * 1024;
const max_events_per_pump = 128;

/// A WebUI callback event, with every borrowed string copied.
const EventKind = enum {
    bridge,
    connected,
    disconnected,
};

const PendingEvent = struct {
    kind: EventKind,
    window: u32,
    a: []u8 = &.{},
    b: []u8 = &.{},
    payload: []u8 = &.{},
};

const Exposure = struct {
    key: []u8,
    descriptor: []u8,
};

const InvokeState = enum {
    fresh,
    dispatched,
    settled,
};

pub const PendingInvoke = struct {
    id: u64,
    channel: []u8,
    args: []u8,
    resolve: Value,
    reject: Value,
    state: InvokeState = .fresh,
    ok: bool = false,
    result: []u8 = &.{},
    failure: []u8 = &.{},
};

const Preload = struct {
    desktop: *Desktop,
    window: *Window,
    js_rt: *quickjs.Runtime,
    ctx: *quickjs.Context,
    host: Host,
    exposures: std.ArrayList(Exposure) = .empty,
    pending: std.ArrayList(*PendingInvoke) = .empty,
    next_id: u64 = 1,

    fn init(desktop: *Desktop, window: *Window, path: []const u8) !*Preload {
        const allocator = desktop.allocator;
        const self = try allocator.create(Preload);
        errdefer allocator.destroy(self);

        const js_rt = try quickjs.Runtime.init();
        errdefer js_rt.deinit();
        const ctx = try quickjs.Context.init(js_rt);
        errdefer ctx.deinit();

        self.* = .{
            .desktop = desktop,
            .window = window,
            .js_rt = js_rt,
            .ctx = ctx,
            // The preload context shares the process subsystems but gets its
            // own role and module allowlist.
            .host = .{
                .allocator = allocator,
                .io = desktop.host.io,
                .ctx = ctx,
                .loop = desktop.host.loop,
                .out = desktop.host.out,
                .fs = desktop.host.fs,
                .rt = desktop.host.rt,
                .children = desktop.host.children,
                .net = desktop.host.net,
                .http = desktop.host.http,
                .fetch = desktop.host.fetch,
                .role = .preload,
                .desktop = desktop,
                .window_id = window.id,
                .argv = desktop.host.argv,
                .environ = desktop.host.environ,
                .entry = null,
            },
        };
        ctx.setOpaque(Host, &self.host);
        js_rt.setModuleLoaderFunc(Host, &self.host, module.normalize, module.load);

        // Registration from inside the preload looks up the window's preload;
        // publish it before evaluation and roll back if evaluation fails.
        window.preload = self;
        errdefer {
            window.preload = null;
            self.deinitContents();
        }

        const source = std.Io.Dir.cwd().readFileAllocOptions(
            desktop.io,
            path,
            allocator,
            .limited(max_module_bytes),
            .of(u8),
            0,
        ) catch |err| {
            std.debug.print("jsz: cannot read preload '{s}': {s}\n", .{ path, @errorName(err) });
            return error.PreloadLoadFailed;
        };
        defer allocator.free(source);

        const filename = try allocator.dupeSentinel(u8, path, 0);
        defer allocator.free(filename);

        const value = ctx.eval(source, filename, .{ .type = .module });
        defer value.deinit(ctx);
        if (value.isException()) {
            reportPreloadException(ctx);
            return error.PreloadLoadFailed;
        }
        self.drainJobs();
        if (value.isPromise() and value.promiseState(ctx) == .rejected) {
            const reason = value.promiseResult(ctx);
            defer reason.deinit(ctx);
            reportValue(ctx, reason);
            return error.PreloadLoadFailed;
        }
        return self;
    }

    fn deinit(self: *Preload) void {
        self.deinitContents();
        self.ctx.deinit();
        self.js_rt.deinit();
        self.desktop.allocator.destroy(self);
    }

    fn deinitContents(self: *Preload) void {
        const allocator = self.desktop.allocator;
        for (self.pending.items) |req| {
            req.resolve.deinit(self.ctx);
            req.reject.deinit(self.ctx);
            allocator.free(req.channel);
            allocator.free(req.args);
            if (req.result.len > 0) allocator.free(req.result);
            if (req.failure.len > 0) allocator.free(req.failure);
            allocator.destroy(req);
        }
        self.pending.deinit(allocator);
        for (self.exposures.items) |exposure| {
            allocator.free(exposure.key);
            allocator.free(exposure.descriptor);
        }
        self.exposures.deinit(allocator);
    }

    fn drainJobs(self: *Preload) void {
        while (self.js_rt.isJobPending()) {
            _ = self.js_rt.executePendingJob() catch {
                reportPreloadException(self.ctx);
                return;
            };
        }
    }
};

const Window = struct {
    desktop: *Desktop,
    id: u32,
    handle: @TypeOf(webui.newWindow()),
    width: u32 = 800,
    height: u32 = 600,
    title: []u8 = &.{},
    url: []u8 = &.{},
    html: []u8 = &.{},
    shown: bool = false,
    hidden: bool = false,
    destroyed: bool = false,
    refed: bool = false,
    preload: ?*Preload = null,
    next_request: u64 = 1,

    fn deinit(self: *Window) void {
        const allocator = self.desktop.allocator;
        if (self.preload) |preload| preload.deinit();
        if (self.title.len > 0) allocator.free(self.title);
        if (self.url.len > 0) allocator.free(self.url);
        if (self.html.len > 0) allocator.free(self.html);
        allocator.destroy(self);
    }
};

pub const Desktop = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    host: *Host,
    loop: *EventLoop,
    queue: *jobs.Queue,
    windows: std.ArrayList(*Window) = .empty,
    events: std.ArrayList(PendingEvent) = .empty,
    events_mutex: zio.os.Mutex = .init(),
    next_id: u32 = 1,
    started: bool = false,
    closing: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        host: *Host,
        loop: *EventLoop,
        queue: *jobs.Queue,
    ) !*Desktop {
        const self = try allocator.create(Desktop);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .host = host,
            .loop = loop,
            .queue = queue,
        };

        // `showWv` must not block waiting for the page to connect; the event
        // loop owns the GUI pump.
        webui.setConfig(.show_wait_connection, false);
        webui.setConfig(.multi_client, false);
        webui.setTimeout(15);
        self.started = true;
        return self;
    }

    pub fn deinit(self: *Desktop) void {
        self.closing = true;
        self.started = false;
        for (self.windows.items) |window| window.deinit();
        self.windows.deinit(self.allocator);

        self.events_mutex.lock();
        for (self.events.items) |event| self.freeEvent(event);
        self.events.clearRetainingCapacity();
        self.events_mutex.unlock();
        self.events.deinit(self.allocator);
        self.events_mutex.deinit();

        webui.exit();
        self.allocator.destroy(self);
    }

    // ------------------------------------------------------------------
    // Pump interface used by EventLoop
    // ------------------------------------------------------------------

    pub fn active(self: *Desktop) bool {
        if (!self.started or self.closing) return false;
        for (self.windows.items) |window| {
            if (window.shown and !window.destroyed) return true;
        }
        return false;
    }

    pub fn pump(self: *Desktop) void {
        if (!self.active()) return;

        const alive = webui.waitAsync();
        self.dispatchEvents();
        if (!alive) {
            // Every WebUI window is gone. Mark them closed so JS observes the
            // disconnection even when the backend did not send an event.
            for (self.windows.items) |window| {
                if (!window.destroyed and window.shown) self.markClosed(window);
            }
        }
    }

    // ------------------------------------------------------------------
    // Window lifecycle
    // ------------------------------------------------------------------

    pub fn createWindow(
        self: *Desktop,
        width: u32,
        height: u32,
        title: []const u8,
        show: bool,
        resizable: bool,
    ) !u32 {
        if (!self.started) return error.DesktopNotStarted;

        const handle = webui.newWindow();
        if (handle.window_handle == 0) return error.WindowCreationFailed;

        const window = try self.allocator.create(Window);
        errdefer self.allocator.destroy(window);
        window.* = .{
            .desktop = self,
            .id = self.next_id,
            .handle = handle,
            .width = if (width == 0) 800 else width,
            .height = if (height == 0) 600 else height,
            .hidden = !show,
        };
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        if (title.len > 0) window.title = try self.allocator.dupe(u8, title);
        errdefer if (window.title.len > 0) self.allocator.free(window.title);

        handle.setSize(window.width, window.height);
        if (!resizable) handle.setResizable(false);
        if (window.hidden) handle.setHide(true);

        _ = handle.bind("jszBridge", onBridgeCallback) catch {
            self.allocator.destroy(window);
            return error.WindowBindFailed;
        };
        handle.setContext("jszBridge", self);

        _ = handle.bind("", onWindowEvent) catch {
            self.allocator.destroy(window);
            return error.WindowBindFailed;
        };
        handle.setContext("", self);

        try self.windows.append(self.allocator, window);
        return window.id;
    }

    pub fn loadFile(self: *Desktop, id: u32, path: []const u8, preload_path: ?[]const u8) !void {
        const window = self.windowById(id) orelse return error.WindowNotFound;
        if (window.destroyed) return error.WindowClosed;

        if (preload_path) |preload_file| {
            if (window.preload) |existing| {
                existing.deinit();
                window.preload = null;
            }
            window.preload = try Preload.init(self, window, preload_file);
        }

        const absolute = if (std.fs.path.isAbsolute(path))
            try self.allocator.dupe(u8, path)
        else blk: {
            const cwd = std.process.currentPathAlloc(self.io, self.allocator) catch ".";
            defer if (!std.mem.eql(u8, cwd, ".")) self.allocator.free(cwd);
            break :blk try std.fs.path.resolveAlloc(self.allocator, &.{ cwd, path });
        };
        defer self.allocator.free(absolute);

        const source = std.Io.Dir.cwd().readFileAllocOptions(
            self.io,
            absolute,
            self.allocator,
            .limited(max_module_bytes),
            .of(u8),
            0,
        ) catch |err| {
            std.debug.print("jsz: cannot read '{s}': {s}\n", .{ absolute, @errorName(err) });
            return error.LoadFileFailed;
        };
        defer self.allocator.free(source);

        const root = std.fs.path.dirname(absolute) orelse ".";
        const root_z = try self.allocator.dupeSentinel(u8, root, 0);
        defer self.allocator.free(root_z);
        try window.handle.setRootFolder(root_z);

        const html = try self.buildDocument(window, source);
        defer self.allocator.free(html);
        const html_z = try self.allocator.dupeSentinel(u8, html, 0);
        defer self.allocator.free(html_z);

        try window.handle.showWv(html_z);
        window.shown = true;
        if (!window.refed) {
            self.loop.ref();
            window.refed = true;
        }

        if (window.url.len > 0) self.allocator.free(window.url);
        window.url = try std.mem.concat(self.allocator, u8, &.{ "file://", absolute });
        if (window.html.len > 0) self.allocator.free(window.html);
        window.html = try self.allocator.dupe(u8, html);
    }

    pub fn loadUrl(self: *Desktop, id: u32, url: []const u8) !void {
        const window = self.windowById(id) orelse return error.WindowNotFound;
        if (window.destroyed) return error.WindowClosed;
        if (!std.mem.startsWith(u8, url, "http://127.0.0.1") and
            !std.mem.startsWith(u8, url, "http://localhost") and
            !std.mem.startsWith(u8, url, "https://127.0.0.1") and
            !std.mem.startsWith(u8, url, "https://localhost"))
        {
            return error.UnsupportedUrl;
        }

        const url_z = try self.allocator.dupeSentinel(u8, url, 0);
        defer self.allocator.free(url_z);

        try window.handle.showWv(url_z);
        window.shown = true;
        if (!window.refed) {
            self.loop.ref();
            window.refed = true;
        }
        if (window.url.len > 0) self.allocator.free(window.url);
        window.url = try self.allocator.dupe(u8, url);
    }

    pub fn showWindow(self: *Desktop, id: u32) !void {
        const window = self.windowById(id) orelse return error.WindowNotFound;
        if (window.destroyed) return error.WindowClosed;
        if (window.hidden) {
            window.handle.setHide(false);
            window.hidden = false;
        }
        if (!window.shown) {
            if (window.html.len == 0) return error.NotLoaded;
            const html_z = try self.allocator.dupeSentinel(u8, window.html, 0);
            defer self.allocator.free(html_z);
            try window.handle.showWv(html_z);
            window.shown = true;
            if (!window.refed) {
                self.loop.ref();
                window.refed = true;
            }
        }
        const payload = std.fmt.allocPrint(self.allocator, "{{\"id\":{d}}}", .{window.id}) catch return;
        defer self.allocator.free(payload);
        self.emitToMain("window-show", payload);
    }

    pub fn hideWindow(self: *Desktop, id: u32) void {
        const window = self.windowById(id) orelse return;
        window.handle.setHide(true);
        window.hidden = true;
    }

    pub fn closeWindow(self: *Desktop, id: u32) void {
        const window = self.windowById(id) orelse return;
        if (window.destroyed) return;
        window.handle.close();
        window.shown = false;
        if (window.refed) {
            self.loop.unref();
            window.refed = false;
        }
        self.markClosed(window);
    }

    pub fn destroyWindow(self: *Desktop, id: u32) void {
        const window = self.windowById(id) orelse return;
        if (window.destroyed) return;
        window.handle.destroy();
        self.markClosed(window);
    }

    pub fn isVisible(self: *Desktop, id: u32) bool {
        const window = self.windowById(id) orelse return false;
        if (window.destroyed or !window.shown) return false;
        if (window.hidden) return false;
        return window.handle.isShown();
    }

    pub fn isDestroyed(self: *Desktop, id: u32) bool {
        const window = self.windowById(id) orelse return true;
        return window.destroyed;
    }

    pub fn setTitle(self: *Desktop, id: u32, title: []const u8) void {
        const window = self.windowById(id) orelse return;
        if (window.title.len > 0) self.allocator.free(window.title);
        window.title = self.allocator.dupe(u8, title) catch &.{};
    }

    pub fn windowUrl(self: *Desktop, id: u32) []const u8 {
        const window = self.windowById(id) orelse return "";
        return window.url;
    }

    // ------------------------------------------------------------------
    // Renderer messaging
    // ------------------------------------------------------------------

    pub fn sendToRenderer(
        self: *Desktop,
        id: u32,
        channel: []const u8,
        args_json: []const u8,
    ) !void {
        const window = self.windowById(id) orelse return error.WindowNotFound;
        if (window.destroyed or !window.shown) return error.WindowClosed;

        const channel_js = try jsonQuote(self.allocator, channel);
        defer self.allocator.free(channel_js);
        const script = try std.fmt.allocPrint(
            self.allocator,
            "if (window.__jszBridgeEvent) window.__jszBridgeEvent({s}, {s});",
            .{ channel_js, args_json },
        );
        defer self.allocator.free(script);
        const script_z = try self.allocator.dupeSentinel(u8, script, 0);
        defer self.allocator.free(script_z);
        window.handle.run(script_z);
    }

    // ------------------------------------------------------------------
    // Native dialogs and shell
    // ------------------------------------------------------------------

    pub fn showOpenDialog(self: *Desktop, options_json: []const u8) ![]u8 {
        const DialogOptions = struct {
            title: ?[]const u8 = null,
            defaultPath: ?[]const u8 = null,
            buttonLabel: ?[]const u8 = null,
            properties: ?[]const []const u8 = null,
            filters: ?[]const struct {
                name: []const u8 = "",
                extensions: []const []const u8 = &.{},
            } = null,
        };

        var parsed = std.json.parseFromSlice(DialogOptions, self.allocator, options_json, .{
            .ignore_unknown_fields = true,
        }) catch return error.InvalidDialogOptions;
        defer parsed.deinit();
        const options = parsed.value;

        var directory = false;
        var multiple = false;
        if (options.properties) |properties| {
            for (properties) |property| {
                if (std.mem.eql(u8, property, "openDirectory")) directory = true;
                if (std.mem.eql(u8, property, "multiSelections")) multiple = true;
            }
        }

        var script: std.Io.Writer.Allocating = .init(self.allocator);
        defer script.deinit();
        const out = &script.writer;

        if (directory) {
            try out.writeAll("set theResult to choose folder");
        } else {
            try out.writeAll("set theResult to choose file");
        }
        if (options.title) |title| {
            const quoted = try appleScriptQuote(self.allocator, title);
            defer self.allocator.free(quoted);
            try out.print(" with prompt {s}", .{quoted});
        }
        if (options.defaultPath) |path| {
            const quoted = try appleScriptQuote(self.allocator, path);
            defer self.allocator.free(quoted);
            try out.print(" default location (POSIX file {s})", .{quoted});
        }
        if (!directory) {
            if (options.filters) |filters| {
                var first = true;
                for (filters) |filter| {
                    for (filter.extensions) |extension| {
                        if (first) {
                            try out.writeAll(" of type {");
                            first = false;
                        } else {
                            try out.writeAll(", ");
                        }
                        const quoted = try appleScriptQuote(self.allocator, extension);
                        defer self.allocator.free(quoted);
                        try out.writeAll(quoted);
                    }
                }
                if (!first) try out.writeAll("}");
            }
        }
        if (multiple) try out.writeAll(" with multiple selections allowed");
        try out.writeAll("\n");
        if (multiple) {
            try out.writeAll(
                \\set outputText to ""
                \\repeat with itemPath in theResult
                \\  set outputText to outputText & (POSIX path of itemPath) & linefeed
                \\end repeat
                \\return outputText
                \\
            );
        } else {
            try out.writeAll("return POSIX path of theResult\n");
        }

        const script_z = try self.allocator.dupeSentinel(u8, script.writer.buffer[0..script.writer.end], 0);
        defer self.allocator.free(script_z);

        const child = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "/usr/bin/osascript", "-e", script_z },
        });
        defer self.allocator.free(child.stdout);
        defer self.allocator.free(child.stderr);

        const canceled = switch (child.term) {
            .exited => |status| status != 0,
            else => true,
        };

        var result: std.Io.Writer.Allocating = .init(self.allocator);
        defer result.deinit();
        const res = &result.writer;

        if (canceled) {
            try res.writeAll("{\"canceled\":true,\"filePaths\":[]}");
            return result.toOwnedSlice();
        }

        try res.writeAll("{\"canceled\":false,\"filePaths\":[");
        var index: usize = 0;
        var it = std.mem.splitScalar(u8, child.stdout, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r\n");
            if (line.len == 0) continue;
            if (index > 0) try res.writeByte(',');
            const quoted = try jsonQuote(self.allocator, line);
            defer self.allocator.free(quoted);
            try res.writeAll(quoted);
            index += 1;
        }
        try res.writeAll("]}");
        return result.toOwnedSlice();
    }

    pub fn openExternal(self: *Desktop, url: []const u8) !void {
        if (!std.mem.startsWith(u8, url, "https://") and
            !std.mem.startsWith(u8, url, "http://"))
        {
            return error.UnsupportedScheme;
        }
        const child = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "/usr/bin/open", url },
        });
        defer self.allocator.free(child.stdout);
        defer self.allocator.free(child.stderr);
        switch (child.term) {
            .exited => |status| if (status != 0) return error.OpenFailed,
            else => return error.OpenFailed,
        }
    }

    pub fn quit(self: *Desktop, code: u8) void {
        self.closing = true;
        for (self.windows.items) |window| {
            if (!window.destroyed) {
                window.handle.destroy();
                window.destroyed = true;
                window.shown = false;
                if (window.refed) {
                    self.loop.unref();
                    window.refed = false;
                }
            }
        }
        self.loop.exit_code = code;
        self.loop.stop();
        self.queue.notify();
    }

    pub fn version(self: *Desktop) []const u8 {
        _ = self;
        return "0.0.0";
    }

    // ------------------------------------------------------------------
    // Event queue
    // ------------------------------------------------------------------

    fn enqueue(
        self: *Desktop,
        kind: EventKind,
        window: u32,
        a: []const u8,
        b: []const u8,
        payload: []const u8,
    ) void {
        if (payload.len > max_bridge_payload) return;
        const allocator = self.allocator;

        const a_copy = allocator.dupe(u8, a) catch return;
        errdefer allocator.free(a_copy);
        const b_copy = allocator.dupe(u8, b) catch return;
        errdefer allocator.free(b_copy);
        const payload_copy = allocator.dupe(u8, payload) catch return;

        self.events_mutex.lock();
        defer self.events_mutex.unlock();
        if (self.events.items.len >= max_events_per_pump * 16) {
            allocator.free(a_copy);
            allocator.free(b_copy);
            allocator.free(payload_copy);
            return;
        }
        self.events.append(allocator, .{
            .kind = kind,
            .window = window,
            .a = a_copy,
            .b = b_copy,
            .payload = payload_copy,
        }) catch {
            allocator.free(a_copy);
            allocator.free(b_copy);
            allocator.free(payload_copy);
        };
        self.queue.notify();
    }

    fn freeEvent(self: *Desktop, event: PendingEvent) void {
        if (event.a.len > 0) self.allocator.free(event.a);
        if (event.b.len > 0) self.allocator.free(event.b);
        if (event.payload.len > 0) self.allocator.free(event.payload);
    }

    fn dispatchEvents(self: *Desktop) void {
        var batch: std.ArrayList(PendingEvent) = .empty;
        defer batch.deinit(self.allocator);

        self.events_mutex.lock();
        if (self.events.items.len == 0) {
            self.events_mutex.unlock();
            return;
        }
        batch = self.events;
        self.events = .empty;
        self.events_mutex.unlock();

        for (batch.items) |event| {
            defer self.freeEvent(event);
            const window = self.windowById(event.window) orelse continue;
            switch (event.kind) {
                .bridge => self.handleBridge(window, event.a, event.b, event.payload),
                .connected => {
                    const payload = std.fmt.allocPrint(self.allocator, "{{\"id\":{d}}}", .{window.id}) catch "";
                    defer if (payload.len > 0) self.allocator.free(payload);
                    self.emitToMain("did-finish-load", payload);
                },
                .disconnected => self.markClosed(window),
            }
        }
    }

    fn handleBridge(
        self: *Desktop,
        window: *Window,
        kind: []const u8,
        request_id: []const u8,
        payload: []const u8,
    ) void {
        if (window.destroyed) return;
        if (std.mem.eql(u8, kind, "api")) {
            self.callExposed(window, request_id, payload);
        } else if (std.mem.eql(u8, kind, "send")) {
            self.dispatchIpcSend(window, payload);
        }
    }

    fn markClosed(self: *Desktop, window: *Window) void {
        if (window.destroyed) return;
        window.destroyed = true;
        window.shown = false;
        if (window.refed) {
            self.loop.unref();
            window.refed = false;
        }
        const payload = std.fmt.allocPrint(self.allocator, "{{\"id\":{d}}}", .{window.id}) catch return;
        defer self.allocator.free(payload);
        self.emitToMain("window-closed", payload);
    }

    // ------------------------------------------------------------------
    // Preload bridge
    // ------------------------------------------------------------------

    fn callExposed(
        self: *Desktop,
        window: *Window,
        request_id: []const u8,
        payload: []const u8,
    ) void {
        const preload = window.preload orelse {
            self.pageReject(window, request_id, "The window has no preload script");
            return;
        };
        const ctx = preload.ctx;

        const global = ctx.getGlobalObject();
        defer global.deinit(ctx);
        const call_fn = global.getPropertyStr(ctx, "__jszCallExposedPayload");
        defer call_fn.deinit(ctx);
        if (!call_fn.isFunction(ctx)) {
            self.pageReject(window, request_id, "The preload bridge is not initialized");
            return;
        }

        const payload_value = Value.initStringLen(ctx, payload);
        defer payload_value.deinit(ctx);
        const result = call_fn.call(ctx, global, &.{payload_value});
        defer result.deinit(ctx);
        if (result.isException()) {
            const exception = ctx.getException();
            defer exception.deinit(ctx);
            const message = valueToOwned(self.allocator, ctx, exception) catch "preload exception";
            defer self.allocator.free(message);
            self.pageReject(window, request_id, message);
            return;
        }

        const track_fn = global.getPropertyStr(ctx, "__jszTrack");
        defer track_fn.deinit(ctx);
        if (!track_fn.isFunction(ctx)) {
            self.pageReject(window, request_id, "The preload bridge is not initialized");
            return;
        }

        const rid = Value.initStringLen(ctx, request_id);
        defer rid.deinit(ctx);
        const wid = Value.initInt32(@intCast(window.id));
        defer wid.deinit(ctx);
        const ok = Value.initCFunctionData(ctx, preloadResolved, 2, 0, &.{ rid, wid });
        defer ok.deinit(ctx);
        const err = Value.initCFunctionData(ctx, preloadRejected, 2, 0, &.{ rid, wid });
        defer err.deinit(ctx);

        const tracked = track_fn.call(ctx, global, &.{ result, ok, err });
        tracked.deinit(ctx);

        var passes: usize = 0;
        while (passes < 8) : (passes += 1) {
            preload.drainJobs();
            const dispatched = self.dispatchMainRequests(window);
            // The main handler's promise settles in the main context. Drain it
            // here so settlement does not wait for the next loop iteration.
            self.host.loop.drainJobs() catch {};
            const settled = self.settlePreload(window);
            preload.drainJobs();
            if (dispatched == 0 and settled == 0) break;
        }
    }

    fn dispatchMainRequests(self: *Desktop, window: *Window) usize {
        const preload = window.preload orelse return 0;
        const ctx = self.host.ctx;
        const global = ctx.getGlobalObject();
        defer global.deinit(ctx);
        const dispatch_fn = global.getPropertyStr(ctx, "__jszDispatchIpc");
        defer dispatch_fn.deinit(ctx);
        if (!dispatch_fn.isFunction(ctx)) return 0;
        const track_fn = global.getPropertyStr(ctx, "__jszTrack");
        defer track_fn.deinit(ctx);
        if (!track_fn.isFunction(ctx)) return 0;

        var count: usize = 0;
        for (preload.pending.items) |req| {
            if (req.state != .fresh) continue;
            req.state = .dispatched;
            count += 1;

            const rid_text = std.fmt.allocPrint(self.allocator, "{d}", .{req.id}) catch continue;
            defer self.allocator.free(rid_text);
            const rid = Value.initStringLen(ctx, rid_text);
            defer rid.deinit(ctx);
            const wid = Value.initInt32(@intCast(window.id));
            defer wid.deinit(ctx);
            const channel = Value.initStringLen(ctx, req.channel);
            defer channel.deinit(ctx);
            const args = Value.initStringLen(ctx, req.args);
            defer args.deinit(ctx);

            const promise = dispatch_fn.call(ctx, global, &.{ rid, wid, channel, args });
            defer promise.deinit(ctx);
            if (promise.isException()) {
                const exception = ctx.getException();
                exception.deinit(ctx);
                req.state = .settled;
                req.ok = false;
                req.failure = self.allocator.dupe(u8, "ipcMain dispatcher failed") catch &.{};
                continue;
            }

            const ok = Value.initCFunctionData(ctx, mainResolved, 2, 0, &.{ rid, wid });
            defer ok.deinit(ctx);
            const err = Value.initCFunctionData(ctx, mainRejected, 2, 0, &.{ rid, wid });
            defer err.deinit(ctx);
            const tracked = track_fn.call(ctx, global, &.{ promise, ok, err });
            tracked.deinit(ctx);
        }
        return count;
    }

    fn settlePreload(self: *Desktop, window: *Window) usize {
        const preload = window.preload orelse return 0;
        const ctx = preload.ctx;
        var index: usize = 0;
        var count: usize = 0;
        while (index < preload.pending.items.len) {
            const req = preload.pending.items[index];
            if (req.state != .settled) {
                index += 1;
                continue;
            }
            count += 1;
            if (req.ok) {
                const text = Value.initStringLen(ctx, req.result);
                defer text.deinit(ctx);
                const result = req.resolve.call(ctx, .undefined, &.{text});
                result.deinit(ctx);
            } else {
                const err = Value.initError(ctx);
                defer err.deinit(ctx);
                const message = Value.initStringLen(ctx, if (req.failure.len > 0) req.failure else "IPC failed");
                err.setPropertyStr(ctx, "message", message) catch {};
                const result = req.reject.call(ctx, .undefined, &.{err});
                result.deinit(ctx);
            }
            req.resolve.deinit(ctx);
            req.reject.deinit(ctx);
            self.allocator.free(req.channel);
            self.allocator.free(req.args);
            if (req.result.len > 0) self.allocator.free(req.result);
            if (req.failure.len > 0) self.allocator.free(req.failure);
            self.allocator.destroy(req);
            _ = preload.pending.swapRemove(index);
        }
        return count;
    }

    pub fn dispatchIpcSend(self: *Desktop, window: *Window, payload: []const u8) void {
        const ctx = self.host.ctx;
        const global = ctx.getGlobalObject();
        defer global.deinit(ctx);
        const fn_value = global.getPropertyStr(ctx, "__jszDispatchIpcSend");
        defer fn_value.deinit(ctx);
        if (!fn_value.isFunction(ctx)) return;

        const json = payload;
        const walrus = Value.initStringLen(ctx, json);
        defer walrus.deinit(ctx);
        const wid = Value.initInt32(@intCast(window.id));
        defer wid.deinit(ctx);
        const result = fn_value.call(ctx, global, &.{ wid, walrus });
        defer result.deinit(ctx);
        if (result.isException()) {
            const exception = ctx.getException();
            defer exception.deinit(ctx);
            reportValue(ctx, exception);
            return;
        }
        self.host.loop.drainJobs() catch {};
    }

    fn pageResolve(
        self: *Desktop,
        window: *Window,
        request_id: []const u8,
        ok: bool,
        value: []const u8,
    ) void {
        if (window.destroyed or !window.shown) return;
        const rid = jsonQuote(self.allocator, request_id) catch return;
        defer self.allocator.free(rid);

        const body = if (ok)
            std.fmt.allocPrint(self.allocator, "if (window.__jszBridgeResolve) window.__jszBridgeResolve({s}, true, {s});", .{
                rid,
                if (value.len > 0) value else "null",
            }) catch return
        else blk: {
            const msg = jsonQuote(self.allocator, value) catch break :blk @as([]u8, &.{});
            defer if (msg.len > 0) self.allocator.free(msg);
            break :blk std.fmt.allocPrint(
                self.allocator,
                "if (window.__jszBridgeResolve) window.__jszBridgeResolve({s}, false, {s});",
                .{ rid, if (msg.len > 0) msg else "\"desktop bridge error\"" },
            ) catch return;
        };
        defer self.allocator.free(body);
        const script = self.allocator.dupeSentinel(u8, body, 0) catch return;
        defer self.allocator.free(script);
        window.handle.run(script);
    }

    fn pageReject(self: *Desktop, window: *Window, request_id: []const u8, message: []const u8) void {
        self.pageResolve(window, request_id, false, message);
    }

    fn findPending(_: *Desktop, window: *Window, id: u64) ?*PendingInvoke {
        const preload = window.preload orelse return null;
        for (preload.pending.items) |req| {
            if (req.id == id) return req;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // Main-context events
    // ------------------------------------------------------------------

    pub fn emitToMain(self: *Desktop, name: []const u8, payload_json: []const u8) void {
        const ctx = self.host.ctx;
        const global = ctx.getGlobalObject();
        defer global.deinit(ctx);
        const fn_value = global.getPropertyStr(ctx, "__jszDesktopEvent");
        defer fn_value.deinit(ctx);
        if (!fn_value.isFunction(ctx)) return;

        const event_name = Value.initStringLen(ctx, name);
        defer event_name.deinit(ctx);
        const payload = Value.initStringLen(ctx, payload_json);
        defer payload.deinit(ctx);
        const result = fn_value.call(ctx, global, &.{ event_name, payload });
        defer result.deinit(ctx);
        if (result.isException()) {
            const exception = ctx.getException();
            defer exception.deinit(ctx);
            reportValue(ctx, exception);
            return;
        }
        self.host.loop.drainJobs() catch {};
    }

    // ------------------------------------------------------------------
    // Document assembly
    // ------------------------------------------------------------------

    fn buildDocument(self: *Desktop, window: *Window, source: []const u8) ![]u8 {
        var bootstrap: std.Io.Writer.Allocating = .init(self.allocator);
        defer bootstrap.deinit();
        const out = &bootstrap.writer;

        try out.writeAll(
            \\(function(){
            \\  if (window.__jszInstalled) return;
            \\  window.__jszInstalled = true;
            \\  var pending = Object.create(null);
            \\  var nextId = 1;
            \\  window.__jszBridgeCall = function(kind, payload) {
            \\    return new Promise(function(resolve, reject) {
            \\      var id = String(nextId++);
            \\      pending[id] = { resolve: resolve, reject: reject };
            \\      var start = function() {
            \\        var begin = Date.now();
            \\        var attempt = function() {
            \\          if (typeof webui === 'undefined' || !webui.isConnected()) {
            \\            if (Date.now() - begin > 10000) {
            \\              delete pending[id];
            \\              reject(new Error('desktop bridge timed out'));
            \\              return;
            \\            }
            \\            setTimeout(attempt, 20);
            \\            return;
            \\          }
            \\          try {
            \\            webui.call('jszBridge', kind, id, JSON.stringify(payload)).catch(function(err) {
            \\              var item = pending[id];
            \\              if (item) { delete pending[id]; item.reject(err); }
            \\            });
            \\          } catch (err) {
            \\            delete pending[id];
            \\            reject(err);
            \\          }
            \\        };
            \\        attempt();
            \\      };
            \\      // WebUI installs its global from a DOMContentLoaded listener.
            \\      if (typeof webui === 'undefined' && document.readyState === 'loading') {
            \\        document.addEventListener('DOMContentLoaded', start, { once: true });
            \\      } else {
            \\        start();
            \\      }
            \\    });
            \\  };
            \\  window.__jszBridgeResolve = function(id, ok, value) {
            \\    var item = pending[id];
            \\    if (!item) return;
            \\    delete pending[id];
            \\    if (ok) item.resolve(value);
            \\    else item.reject(new Error(value || 'desktop bridge error'));
            \\  };
            \\  window.__jszBridgeEvent = function(channel, payload) {
            \\    window.dispatchEvent(new CustomEvent('jsz-ipc', { detail: { channel: channel, args: payload } }));
            \\  };
            \\  window.__jszExpose = function(key, node, path) {
            \\    if (node.t === 'fn') {
            \\      return function() {
            \\        return window.__jszBridgeCall('api', {
            \\          key: key, path: path, args: Array.prototype.slice.call(arguments)
            \\        });
            \\      };
            \\    }
            \\    if (node.t === 'obj') {
            \\      var object = {};
            \\      var keys = Object.keys(node.v || {});
            \\      for (var i = 0; i < keys.length; i++) {
            \\        var name = keys[i];
            \\        object[name] = window.__jszExpose(key, node.v[name], path.concat([name]));
            \\      }
            \\      return Object.freeze(object);
            \\    }
            \\    return node.v;
            \\  };
            \\})();
            \\
        );

        if (window.preload) |preload| {
            for (preload.exposures.items) |exposure| {
                const key = try jsonQuote(self.allocator, exposure.key);
                defer self.allocator.free(key);
                try out.print("window[{s}] = window.__jszExpose({s}, {s}, []);\n", .{
                    key, key, exposure.descriptor,
                });
            }
        }

        var document: std.Io.Writer.Allocating = .init(self.allocator);
        defer document.deinit();
        const page = &document.writer;

        const needs_webui = !hasWebuiScript(source);
        const injection_at = findInjectionPoint(source);
        if (injection_at) |point| {
            try page.writeAll(source[0..point]);
            if (needs_webui) try page.writeAll("<script src=\"/webui.js\"></script>");
            try page.writeAll("<script>\n");
            try page.writeAll(bootstrap.writer.buffer[0..bootstrap.writer.end]);
            try page.writeAll("</script>\n");
            try page.writeAll(source[point..]);
        } else {
            if (needs_webui) try page.writeAll("<script src=\"/webui.js\"></script>");
            try page.writeAll("<script>\n");
            try page.writeAll(bootstrap.writer.buffer[0..bootstrap.writer.end]);
            try page.writeAll("</script>\n");
            try page.writeAll(source);
        }
        return document.toOwnedSlice();
    }

    fn hasWebuiScript(source: []const u8) bool {
        var index: usize = 0;
        while (std.mem.indexOfPos(u8, source, index, "src=")) |at| {
            const rest = source[at + 4 ..];
            const tag_end = std.mem.indexOfScalar(u8, rest, '>') orelse rest.len;
            const tag = rest[0..@min(tag_end, 1024)];
            const quote_start = std.mem.indexOfAny(u8, tag, "\"'") orelse {
                index = at + 4;
                continue;
            };
            const value = tag[quote_start + 1 ..];
            const quote_end = std.mem.indexOfAny(u8, value, "\"'") orelse value.len;
            if (std.mem.endsWith(u8, value[0..quote_end], "webui.js")) return true;
            index = at + 4;
        }
        return false;
    }

    fn findInjectionPoint(source: []const u8) ?usize {
        // WebUI's script touches `document.body` while it initializes, so it
        // must run after the body element exists. Exposing the bridge here is
        // still before any page script inside the body.
        if (findTagEnd(source, "<body")) |end| return end;
        if (findTagEnd(source, "<head")) |end| return end;
        return null;
    }

    fn findTagEnd(source: []const u8, tag: []const u8) ?usize {
        var index: usize = 0;
        while (index + tag.len <= source.len) : (index += 1) {
            if (!std.ascii.eqlIgnoreCase(source[index .. index + tag.len], tag)) continue;
            const rest = source[index + tag.len ..];
            const close = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
            return index + tag.len + close + 1;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    pub fn windowById(self: *Desktop, id: u32) ?*Window {
        for (self.windows.items) |window| {
            if (window.id == id) return window;
        }
        return null;
    }

    fn windowByHandle(self: *Desktop, handle: usize) ?*Window {
        for (self.windows.items) |window| {
            if (window.handle.window_handle == handle) return window;
        }
        return null;
    }
};

// ----------------------------------------------------------------------
// WebUI callbacks. These run on WebUI worker threads: only copy and queue.
// ----------------------------------------------------------------------

fn onBridgeCallback(event: *webui.Event) void {
    const raw = event.getContext() catch return;
    const self: *Desktop = @ptrCast(@alignCast(raw));
    const window = self.windowByHandle(event.window) orelse return;
    if (window.destroyed) return;

    const count = event.getCount();
    var kind: []const u8 = "";
    var request_id: []const u8 = "";
    var payload: []const u8 = "";
    if (count > 0) kind = event.getStringAt(0);
    if (count > 1) request_id = event.getStringAt(1);
    if (count > 2) payload = event.getStringAt(2);
    self.enqueue(.bridge, window.id, kind, request_id, payload);
    event.returnString("1");
}

fn onWindowEvent(event: *webui.Event) void {
    const raw = event.getContext() catch return;
    const self: *Desktop = @ptrCast(@alignCast(raw));
    const window = self.windowByHandle(event.window) orelse return;
    switch (event.event_type) {
        .EVENT_CONNECTED => self.enqueue(.connected, window.id, "", "", ""),
        .EVENT_DISCONNECTED => self.enqueue(.disconnected, window.id, "", "", ""),
        else => {},
    }
}

// ----------------------------------------------------------------------
// QuickJS callbacks
// ----------------------------------------------------------------------

fn preloadResolved(
    ctx_opt: ?*quickjs.Context,
    _: Value,
    args: []const c.JSValue,
    _: c_int,
    data: [*c]c.JSValue,
) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = ctx.getOpaque(Host) orelse return .undefined;
    const desktop = desktopFromHost(host) orelse return .undefined;
    const request_id = dataString(ctx, data[0]) orelse return .undefined;
    defer ctx.freeCString(request_id.ptr);
    const window_id = dataInt(ctx, data[1]);

    if (args.len == 0) return .undefined;
    const text = valueToOwned(desktop.allocator, ctx, Value.fromCVal(args[0])) catch return .undefined;
    defer desktop.allocator.free(text);
    if (desktop.windowById(window_id)) |window| {
        desktop.pageResolve(window, request_id, true, text);
    }
    return .undefined;
}

fn preloadRejected(
    ctx_opt: ?*quickjs.Context,
    _: Value,
    args: []const c.JSValue,
    _: c_int,
    data: [*c]c.JSValue,
) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = ctx.getOpaque(Host) orelse return .undefined;
    const desktop = desktopFromHost(host) orelse return .undefined;
    const request_id = dataString(ctx, data[0]) orelse return .undefined;
    defer ctx.freeCString(request_id.ptr);
    const window_id = dataInt(ctx, data[1]);

    var message: []u8 = &.{};
    defer if (message.len > 0) desktop.allocator.free(message);
    if (args.len > 0) {
        message = valueToOwned(desktop.allocator, ctx, Value.fromCVal(args[0])) catch &.{};
    }
    if (desktop.windowById(window_id)) |window| {
        desktop.pageResolve(window, request_id, false, if (message.len > 0) message else "preload exception");
    }
    return .undefined;
}

fn mainResolved(
    ctx_opt: ?*quickjs.Context,
    _: Value,
    args: []const c.JSValue,
    _: c_int,
    data: [*c]c.JSValue,
) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = ctx.getOpaque(Host) orelse return .undefined;
    const desktop = desktopFromHost(host) orelse return .undefined;
    const request_id = dataString(ctx, data[0]) orelse return .undefined;
    defer ctx.freeCString(request_id.ptr);
    const window_id = dataInt(ctx, data[1]);

    const window = desktop.windowById(window_id) orelse return .undefined;
    const numeric = std.fmt.parseInt(u64, request_id, 10) catch return .undefined;
    if (desktop.findPending(window, numeric)) |req| {
        req.ok = true;
        if (args.len > 0) {
            req.result = valueToOwned(desktop.allocator, ctx, Value.fromCVal(args[0])) catch &.{};
        }
        req.state = .settled;
    }
    return .undefined;
}

fn mainRejected(
    ctx_opt: ?*quickjs.Context,
    _: Value,
    args: []const c.JSValue,
    _: c_int,
    data: [*c]c.JSValue,
) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = ctx.getOpaque(Host) orelse return .undefined;
    const desktop = desktopFromHost(host) orelse return .undefined;
    const request_id = dataString(ctx, data[0]) orelse return .undefined;
    defer ctx.freeCString(request_id.ptr);
    const window_id = dataInt(ctx, data[1]);

    const window = desktop.windowById(window_id) orelse return .undefined;
    const numeric = std.fmt.parseInt(u64, request_id, 10) catch return .undefined;
    if (desktop.findPending(window, numeric)) |req| {
        req.ok = false;
        if (args.len > 0) {
            req.failure = valueToOwned(desktop.allocator, ctx, Value.fromCVal(args[0])) catch &.{};
        }
        req.state = .settled;
    }
    return .undefined;
}

fn desktopFromHost(host: *Host) ?*Desktop {
    const raw = host.desktop orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn dataString(ctx: *quickjs.Context, value: c.JSValue) ?[:0]const u8 {
    if (!c.JS_IsString(value)) return null;
    const text = Value.fromCVal(value).toZigSlice(ctx) orelse return null;
    return text;
}

fn dataInt(ctx: *quickjs.Context, value: c.JSValue) u32 {
    const number = Value.fromCVal(value).toInt32(ctx) catch return 0;
    if (number <= 0) return 0;
    return @intCast(number);
}

fn valueToOwned(
    allocator: std.mem.Allocator,
    ctx: *quickjs.Context,
    value: Value,
) ![]u8 {
    const text = value.toStringValue(ctx);
    defer text.deinit(ctx);
    if (text.isException()) return error.StringConversionFailed;
    const cstr = text.toCString(ctx) orelse return error.StringConversionFailed;
    defer ctx.freeCString(cstr);
    return allocator.dupe(u8, std.mem.span(cstr));
}

fn reportPreloadException(ctx: *quickjs.Context) void {
    const exception = ctx.getException();
    defer exception.deinit(ctx);
    reportValue(ctx, exception);
}

fn reportValue(ctx: *quickjs.Context, value: Value) void {
    const text = value.toStringValue(ctx);
    defer text.deinit(ctx);
    if (text.isException()) return;
    const cstr = text.toCString(ctx) orelse return;
    defer ctx.freeCString(cstr);
    std.debug.print("jsz desktop: {s}\n", .{std.mem.span(cstr)});
}

fn jsonQuote(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.append(allocator, '"');
    for (input) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0...7, 11, 14...31 => {
                const encoded = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{ch});
                defer allocator.free(encoded);
                try out.appendSlice(allocator, encoded);
            },
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

fn appleScriptQuote(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.append(allocator, '"');
    for (input) |ch| {
        switch (ch) {
            '"', '\\' => {
                try out.append(allocator, '\\');
                try out.append(allocator, ch);
            },
            '\n' => try out.appendSlice(allocator, "\\n"),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

// WebUI callbacks are registered per window; keep the functions referenced so
// the library can always resolve them at comptime.
comptime {
    _ = onBridgeCallback;
    _ = onWindowEvent;
}
