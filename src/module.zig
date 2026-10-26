const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("js/host.zig").Host;
const fs_native = @import("js/fs.zig");

pub const max_module_bytes = 16 * 1024 * 1024;

pub const Builtin = struct {
    name: []const u8,
    source: []const u8,
    native: bool = false,
};

pub const builtin_list = [_]Builtin{
    .{ .name = "node:_fs", .source = "", .native = true },
    .{ .name = "node:fs", .source = @embedFile("builtins/fs.js") },
    .{ .name = "node:fs/promises", .source = @embedFile("builtins/fs_promises.js") },
    .{ .name = "node:path", .source = @embedFile("builtins/path.js") },
};

const probing_suffixes = [_][]const u8{ "", ".js", ".mjs", "/index.js", "/index.mjs" };

pub fn findBuiltin(name: []const u8) ?Builtin {
    for (builtin_list) |builtin| {
        if (std.mem.eql(u8, builtin.name, name)) return builtin;
    }
    return null;
}

fn isBare(spec: []const u8) bool {
    return !std.mem.startsWith(u8, spec, "./") and
        !std.mem.startsWith(u8, spec, "../") and
        !std.mem.startsWith(u8, spec, "/") and
        !std.mem.startsWith(u8, spec, "file:") and
        !std.mem.startsWith(u8, spec, "node:");
}

fn throwOom(ctx: *quickjs.Context) void {
    _ = ctx.throwOutOfMemory();
}

fn fail(
    ctx: *quickjs.Context,
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const msg = allocator.printSentinel(fmt, args, 0) catch {
        throwOom(ctx);
        return;
    };
    defer allocator.free(msg);
    const exc = ctx.throwTypeError(msg);
    exc.deinit(ctx);
}

fn toJsCString(ctx: *quickjs.Context, text: []const u8) ?[*:0]u8 {
    const raw = quickjs.c.js_malloc(ctx.cval(), text.len + 1) orelse {
        throwOom(ctx);
        return null;
    };
    const buf: [*]u8 = @ptrCast(raw);
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    return @ptrCast(buf);
}

pub fn normalize(
    host_opt: ?*Host,
    ctx: *quickjs.Context,
    base: [:0]const u8,
    spec: [:0]const u8,
) ?[*:0]u8 {
    const host = host_opt orelse {
        throwOom(ctx);
        return null;
    };
    const allocator = host.allocator;

    if (std.mem.startsWith(u8, spec, "node:") or isBare(spec)) {
        const canonical = if (std.mem.startsWith(u8, spec, "node:"))
            allocator.dupe(u8, spec) catch {
                throwOom(ctx);
                return null;
            }
        else
            std.fmt.allocPrint(allocator, "node:{s}", .{spec}) catch {
                throwOom(ctx);
                return null;
            };
        defer allocator.free(canonical);

        if (findBuiltin(canonical) == null) {
            fail(ctx, allocator, "Cannot find module '{s}' imported from {s}", .{ spec, base });
            return null;
        }
        return toJsCString(ctx, canonical);
    }

    if (std.mem.startsWith(u8, base, "node:")) {
        fail(ctx, allocator, "Cannot resolve '{s}' from builtin '{s}'", .{ spec, base });
        return null;
    }

    const spec_res: ?[]u8 = resolveSpecifier(host, base, spec) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            fail(ctx, allocator, "Cannot resolve '{s}': {s}", .{ spec, @errorName(err) });
            return null;
        },
    };
    if (spec_res) |resolved| {
        defer allocator.free(resolved);
        return toJsCString(ctx, resolved);
    }
    fail(ctx, allocator, "Cannot find module '{s}' imported from {s}", .{ spec, base });
    return null;
}

fn resolveSpecifier(host: *Host, base: []const u8, spec: []const u8) ![]u8 {
    const allocator = host.allocator;
    const io = host.io;

    const cwd = std.process.currentPathAlloc(io, allocator) catch null;
    defer if (cwd) |path| allocator.free(path);

    const base_dir: []const u8 = if (base.len > 0)
        std.fs.path.dirname(base) orelse "."
    else
        cwd orelse ".";

    const joined = if (std.fs.path.isAbsolute(spec))
        try allocator.dupe(u8, spec)
    else
        try std.fs.path.join(allocator, &.{ base_dir, spec });

    const resolved = try std.fs.path.resolveAlloc(allocator, &.{joined});

    for (probing_suffixes) |suffix| {
        const candidate = try std.mem.concat(allocator, u8, &.{ resolved, suffix });
        if (exists(io, candidate)) {
            allocator.free(resolved);
            allocator.free(joined);
            return candidate;
        }
        allocator.free(candidate);
    }

    allocator.free(resolved);
    allocator.free(joined);
    return error.FileNotFound;
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{ .read = true }) catch return false;
    return true;
}

pub fn load(host_opt: ?*Host, ctx: *quickjs.Context, name: [:0]const u8) ?*quickjs.ModuleDef {
    const host = host_opt orelse {
        throwOom(ctx);
        return null;
    };

    if (findBuiltin(name)) |builtin| {
        if (builtin.native) {
            return fs_native.initModule(ctx) orelse {
                _ = ctx.throwOutOfMemory();
                return null;
            };
        }
        return compile(host, ctx, builtin.source, builtin.name);
    }
    if (std.mem.startsWith(u8, name, "node:")) {
        fail(ctx, host.allocator, "Cannot find module '{s}'", .{name});
        return null;
    }
    return loadFile(host, ctx, name);
}

fn loadFile(host: *Host, ctx: *quickjs.Context, name: []const u8) ?*quickjs.ModuleDef {
    const allocator = host.allocator;
    const source = std.Io.Dir.cwd().readFileAllocOptions(
        host.io,
        name,
        allocator,
        .limited(max_module_bytes),
        .of(u8),
        0,
    ) catch |err| {
        fail(ctx, allocator, "Cannot read module '{s}': {s}", .{ name, @errorName(err) });
        return null;
    };
    defer allocator.free(source);

    return compile(host, ctx, source, name);
}

fn compile(
    host: *Host,
    ctx: *quickjs.Context,
    source: []const u8,
    name: []const u8,
) ?*quickjs.ModuleDef {
    const allocator = host.allocator;
    const zname = allocator.dupeSentinel(u8, name, 0) catch {
        throwOom(ctx);
        return null;
    };
    defer allocator.free(zname);

    const value = ctx.eval(source, zname, .{ .type = .module, .compile_only = true });
    defer value.deinit(ctx);
    if (value.isException()) return null;

    const raw = quickjs.c.JS_VALUE_GET_PTR(value.cval());
    const ptr = raw orelse {
        _ = ctx.throwInternalError("module compilation produced no module definition");
        return null;
    };

    return @ptrCast(@alignCast(ptr));
}

test "normalize maps bare specifiers to node: names" {
    const rt: *quickjs.Runtime = try .init();
    defer rt.deinit();
    const ctx: *quickjs.Context = try .init(rt);
    defer ctx.deinit();

    var host: Host = undefined;
    host.allocator = std.testing.allocator;
    host.ctx = ctx;

    const name = normalize(&host, ctx, "", "path") orelse return error.NormalizeFailed;
    defer ctx.freeCString(name);
    try std.testing.expectEqualStrings("node:path", std.mem.span(name));
}

test "unknown builtin throws instead of resolving" {
    const rt: *quickjs.Runtime = try .init();
    defer rt.deinit();
    const ctx: *quickjs.Context = try .init(rt);
    defer ctx.deinit();

    var host: Host = undefined;
    host.allocator = std.testing.allocator;
    host.ctx = ctx;

    const ok = std.testing.expect(normalize(&host, ctx, "", "node:not_a_builtin") == null);
    const exc = ctx.getException();
    defer exc.deinit(ctx);
    try std.testing.expect(ok and exc.isError());
}

test "embedded path module exposes node-compatible exports" {
    const rt: *quickjs.Runtime = try .init();
    defer rt.deinit();
    const ctx: *quickjs.Context = try .init(rt);
    defer ctx.deinit();

    var host: Host = undefined;
    host.allocator = std.testing.allocator;
    host.ctx = ctx;

    rt.setModuleLoaderFunc(Host, &host, normalize, load);

    const js_source = "import { join, posix } from \"node:path\"; globalThis.__joined = join(\"/a\", \"..\", \"b\", \"c\"); globalThis.__isSame = join === posix.join;";
    const value = ctx.eval(js_source, "<path-test>", .{ .type = .module });
    defer value.deinit(ctx);
    try std.testing.expect(!value.isException());

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);

    const joined = global.getPropertyStr(ctx, "__joined");
    defer joined.deinit(ctx);
    const text_ptr = joined.toCString(ctx);
    defer ctx.freeCString(text_ptr);
    const text: []const u8 = if (text_ptr) |t| t else &[]const u8{};
    try std.testing.expectEqualStrings("/b/c", std.mem.span(text));

    const same = global.getPropertyStr(ctx, "__isSame");
    defer same.deinit(ctx);
    try std.testing.expect(try same.toBool(ctx));
}
