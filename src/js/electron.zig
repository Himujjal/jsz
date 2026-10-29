//! Private native bindings behind the `electron` ESM facades.
//!
//! `node:_electron_main` implements the browser-process side; the preload
//! context sees only `node:_electron_preload`, which carries the bridge
//! transport into the main context.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("host.zig").Host;
const Desktop = @import("../desktop.zig").Desktop;

const Value = quickjs.Value;

fn hostOf(ctx: *quickjs.Context) ?*Host {
    return ctx.getOpaque(Host) orelse {
        _ = ctx.throwInternalError("jsz host is not initialized");
        return null;
    };
}

fn desktopOf(host: *Host) ?*Desktop {
    const raw = host.desktop orelse {
        _ = host.ctx.throwInternalError("desktop mode is not enabled");
        return null;
    };
    return @ptrCast(@alignCast(raw));
}

fn argValue(args: []const quickjs.c.JSValue, index: usize) Value {
    if (index >= args.len) return .undefined;
    return Value.fromCVal(args[index]);
}

fn argInt(ctx: *quickjs.Context, args: []const quickjs.c.JSValue, index: usize) i32 {
    return argValue(args, index).toInt32(ctx) catch 0;
}

fn argBool(ctx: *quickjs.Context, args: []const quickjs.c.JSValue, index: usize) bool {
    return argValue(args, index).toBool(ctx) catch false;
}

fn argString(
    host: *Host,
    ctx: *quickjs.Context,
    args: []const quickjs.c.JSValue,
    index: usize,
    name: [:0]const u8,
) ?[]u8 {
    const value = argValue(args, index);
    if (!value.isString()) {
        const message = std.fmt.allocPrintSentinel(
            host.allocator,
            "The \"{s}\" argument must be of type string",
            .{name},
            0,
        ) catch {
            _ = ctx.throwOutOfMemory();
            return null;
        };
        defer host.allocator.free(message);
        _ = ctx.throwTypeError(message);
        return null;
    }

    const slice = value.toZigSlice(ctx) orelse {
        _ = ctx.throwInternalError("failed to read string argument");
        return null;
    };
    defer ctx.freeCString(slice.ptr);

    return host.allocator.dupe(u8, slice) catch {
        _ = ctx.throwOutOfMemory();
        return null;
    };
}

fn createWindow(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;

    const width = argInt(ctx, args, 0);
    const height = argInt(ctx, args, 1);
    const show_flag = argBool(ctx, args, 2);
    const resizable = argBool(ctx, args, 3);
    const title = argString(host, ctx, args, 4, "title") orelse return .undefined;
    defer host.allocator.free(title);

    const id = desktop.createWindow(
        if (width > 0) @intCast(width) else 800,
        if (height > 0) @intCast(height) else 600,
        title,
        show_flag,
        resizable,
    ) catch return ctx.throwTypeError("failed to create the native window");
    return Value.initInt32(@intCast(id));
}

fn loadFile(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;

    const id = argInt(ctx, args, 0);
    const path = argString(host, ctx, args, 1, "filePath") orelse return .undefined;
    defer host.allocator.free(path);

    var preload_path: ?[]u8 = null;
    defer if (preload_path) |value| host.allocator.free(value);
    if (args.len > 2 and argValue(args, 2).isString()) {
        preload_path = argString(host, ctx, args, 2, "preload") orelse return .undefined;
    }

    desktop.loadFile(@intCast(id), path, preload_path) catch |err| {
        return ctx.throwTypeError(switch (err) {
            error.WindowNotFound => "the window does not exist",
            error.WindowClosed => "the window is destroyed",
            error.LoadFileFailed => "failed to read the HTML file",
            error.PreloadLoadFailed => "failed to evaluate the preload script",
            else => "failed to load the file",
        });
    };
    return .undefined;
}

fn loadUrl(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;

    const id = argInt(ctx, args, 0);
    const url = argString(host, ctx, args, 1, "url") orelse return .undefined;
    defer host.allocator.free(url);

    desktop.loadUrl(@intCast(id), url) catch |err| {
        return ctx.throwTypeError(switch (err) {
            error.WindowNotFound => "the window does not exist",
            error.WindowClosed => "the window is destroyed",
            error.UnsupportedUrl => "only explicit loopback http(s) URLs are supported",
            else => "failed to load the URL",
        });
    };
    return .undefined;
}

fn show(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;
    desktop.showWindow(@intCast(argInt(ctx, args, 0))) catch |err| {
        return ctx.throwTypeError(switch (err) {
            error.NotLoaded => "the window has no document to show",
            else => "failed to show the window",
        });
    };
    return .undefined;
}

fn hide(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;
    desktop.hideWindow(@intCast(argInt(ctx, args, 0)));
    return .undefined;
}

fn close(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;
    desktop.closeWindow(@intCast(argInt(ctx, args, 0)));
    return .undefined;
}

fn destroy(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;
    desktop.destroyWindow(@intCast(argInt(ctx, args, 0)));
    return .undefined;
}

fn isVisible(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;
    return Value.initBool(desktop.isVisible(@intCast(argInt(ctx, args, 0))));
}

fn isDestroyed(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;
    return Value.initBool(desktop.isDestroyed(@intCast(argInt(ctx, args, 0))));
}

fn send(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;

    const id = argInt(ctx, args, 0);
    const channel = argString(host, ctx, args, 1, "channel") orelse return .undefined;
    defer host.allocator.free(channel);
    const payload = argString(host, ctx, args, 2, "args") orelse return .undefined;
    defer host.allocator.free(payload);

    desktop.sendToRenderer(@intCast(id), channel, payload) catch {
        return ctx.throwTypeError("the window is closed");
    };
    return .undefined;
}

fn showOpenDialog(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;

    const options = argString(host, ctx, args, 0, "options") orelse return .undefined;
    defer host.allocator.free(options);

    const result = desktop.showOpenDialog(options) catch |err| {
        return ctx.throwTypeError(switch (err) {
            error.InvalidDialogOptions => "invalid dialog options",
            else => "the native file picker failed",
        });
    };
    defer host.allocator.free(result);
    return Value.initStringLen(ctx, result);
}

fn openExternal(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;

    const url = argString(host, ctx, args, 0, "url") orelse return .undefined;
    defer host.allocator.free(url);

    desktop.openExternal(url) catch |err| {
        return ctx.throwTypeError(switch (err) {
            error.UnsupportedScheme => "only http: and https: URLs may be opened",
            else => "failed to open the URL",
        });
    };
    return .undefined;
}

fn quit(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;
    desktop.quit(0);
    return .undefined;
}

fn exit(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;
    const code = argInt(ctx, args, 0);
    desktop.quit(@truncate(@as(u32, @bitCast(code))));
    return .undefined;
}

fn getVersion(ctx_opt: ?*quickjs.Context, _: Value, _: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;
    return Value.initStringLen(ctx, desktop.version());
}

fn getUrl(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;
    return Value.initStringLen(ctx, desktop.windowUrl(@intCast(argInt(ctx, args, 0))));
}

fn setTitle(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;
    const id = argInt(ctx, args, 0);
    const title = argString(host, ctx, args, 1, "title") orelse return .undefined;
    defer host.allocator.free(title);
    desktop.setTitle(@intCast(id), title);
    return .undefined;
}

// ----------------------------------------------------------------------
// Preload bindings
// ----------------------------------------------------------------------

fn registerExposed(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;
    const window = desktop.windowById(host.window_id) orelse {
        return ctx.throwInternalError("the preload window is closed");
    };
    const preload = window.preload orelse {
        return ctx.throwInternalError("the preload context is not initialized");
    };

    const key = argString(host, ctx, args, 0, "key") orelse return .undefined;
    defer host.allocator.free(key);
    const descriptor = argString(host, ctx, args, 1, "api") orelse return .undefined;
    defer host.allocator.free(descriptor);

    for (preload.exposures.items) |exposure| {
        if (std.mem.eql(u8, exposure.key, key)) {
            return ctx.throwTypeError("contextBridge key is already exposed");
        }
    }

    const key_copy = host.allocator.dupe(u8, key) catch return ctx.throwOutOfMemory();
    errdefer host.allocator.free(key_copy);
    const descriptor_copy = host.allocator.dupe(u8, descriptor) catch return ctx.throwOutOfMemory();
    errdefer host.allocator.free(descriptor_copy);

    preload.exposures.append(host.allocator, .{
        .key = key_copy,
        .descriptor = descriptor_copy,
    }) catch {
        host.allocator.free(key_copy);
        host.allocator.free(descriptor_copy);
        return ctx.throwOutOfMemory();
    };
    return .undefined;
}

fn preloadInvoke(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;
    const window = desktop.windowById(host.window_id) orelse {
        return ctx.throwInternalError("the preload window is closed");
    };
    const preload = window.preload orelse {
        return ctx.throwInternalError("the preload context is not initialized");
    };

    const channel = argString(host, ctx, args, 0, "channel") orelse return .undefined;
    defer host.allocator.free(channel);
    const payload = argString(host, ctx, args, 1, "args") orelse return .undefined;
    defer host.allocator.free(payload);
    if (channel.len == 0) return ctx.throwTypeError("The \"channel\" argument must not be empty");

    const promise = Value.initPromiseCapability(ctx);
    const request = host.allocator.create(@import("../desktop.zig").PendingInvoke) catch {
        promise.deinit(ctx);
        return ctx.throwOutOfMemory();
    };
    request.* = .{
        .id = preload.next_id,
        .channel = host.allocator.dupe(u8, channel) catch {
            host.allocator.destroy(request);
            promise.deinit(ctx);
            return ctx.throwOutOfMemory();
        },
        .args = host.allocator.dupe(u8, payload) catch {
            host.allocator.free(request.channel);
            host.allocator.destroy(request);
            promise.deinit(ctx);
            return ctx.throwOutOfMemory();
        },
        .resolve = promise.resolve,
        .reject = promise.reject,
    };
    preload.next_id +%= 1;
    preload.pending.append(host.allocator, request) catch {
        host.allocator.free(request.channel);
        host.allocator.free(request.args);
        host.allocator.destroy(request);
        promise.deinit(ctx);
        return ctx.throwOutOfMemory();
    };
    return promise.value;
}

fn preloadSend(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;
    const desktop = desktopOf(host) orelse return .undefined;
    const window = desktop.windowById(host.window_id) orelse {
        return ctx.throwInternalError("the preload window is closed");
    };

    const channel = argString(host, ctx, args, 0, "channel") orelse return .undefined;
    defer host.allocator.free(channel);
    const payload = argString(host, ctx, args, 1, "args") orelse return .undefined;
    defer host.allocator.free(payload);

    const quoted = quoteJson(host.allocator, channel) catch return ctx.throwOutOfMemory();
    defer host.allocator.free(quoted);
    const combined = std.fmt.allocPrint(host.allocator, "{{\"channel\":{s},\"args\":{s}}}", .{
        quoted,
        payload,
    }) catch return ctx.throwOutOfMemory();
    defer host.allocator.free(combined);
    desktop.dispatchIpcSend(window, combined);
    return .undefined;
}

fn quoteJson(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.writeByte('"');
    for (input) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
    return out.toOwnedSlice();
}

// ----------------------------------------------------------------------
// Module registration
// ----------------------------------------------------------------------

const Export = struct {
    name: [:0]const u8,
    func: quickjs.cfunc.Func,
    nargs: i32,
};

const main_exports = [_]Export{
    .{ .name = "createWindow", .func = createWindow, .nargs = 5 },
    .{ .name = "loadFile", .func = loadFile, .nargs = 3 },
    .{ .name = "loadUrl", .func = loadUrl, .nargs = 2 },
    .{ .name = "show", .func = show, .nargs = 1 },
    .{ .name = "hide", .func = hide, .nargs = 1 },
    .{ .name = "close", .func = close, .nargs = 1 },
    .{ .name = "destroy", .func = destroy, .nargs = 1 },
    .{ .name = "isVisible", .func = isVisible, .nargs = 1 },
    .{ .name = "isDestroyed", .func = isDestroyed, .nargs = 1 },
    .{ .name = "send", .func = send, .nargs = 3 },
    .{ .name = "showOpenDialog", .func = showOpenDialog, .nargs = 1 },
    .{ .name = "openExternal", .func = openExternal, .nargs = 1 },
    .{ .name = "quit", .func = quit, .nargs = 0 },
    .{ .name = "exit", .func = exit, .nargs = 1 },
    .{ .name = "getVersion", .func = getVersion, .nargs = 0 },
    .{ .name = "getUrl", .func = getUrl, .nargs = 1 },
    .{ .name = "setTitle", .func = setTitle, .nargs = 2 },
};

const preload_exports = [_]Export{
    .{ .name = "registerExposed", .func = registerExposed, .nargs = 2 },
    .{ .name = "invoke", .func = preloadInvoke, .nargs = 2 },
    .{ .name = "send", .func = preloadSend, .nargs = 2 },
};

fn mainInit(ctx: *quickjs.Context, def: *quickjs.ModuleDef) bool {
    inline for (main_exports) |entry| {
        const function = Value.initCFunction(ctx, entry.func, entry.name, entry.nargs);
        if (!def.setExport(ctx, entry.name, function)) return false;
    }
    return true;
}

fn preloadInit(ctx: *quickjs.Context, def: *quickjs.ModuleDef) bool {
    inline for (preload_exports) |entry| {
        const function = Value.initCFunction(ctx, entry.func, entry.name, entry.nargs);
        if (!def.setExport(ctx, entry.name, function)) return false;
    }
    return true;
}

pub fn initMainModule(ctx: *quickjs.Context) ?*quickjs.ModuleDef {
    const def = quickjs.ModuleDef.init(ctx, "node:_electron_main", mainInit) orelse return null;
    inline for (main_exports) |entry| {
        _ = def.addExport(ctx, entry.name);
    }
    return def;
}

pub fn initPreloadModule(ctx: *quickjs.Context) ?*quickjs.ModuleDef {
    const def = quickjs.ModuleDef.init(ctx, "node:_electron_preload", preloadInit) orelse return null;
    inline for (preload_exports) |entry| {
        _ = def.addExport(ctx, entry.name);
    }
    return def;
}
