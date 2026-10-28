const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("js/host.zig").Host;
const encoding_native = @import("js/encoding.zig");
const fs_native = @import("js/fs.zig");
const process_native = @import("js/process.zig");
const crypto_native = @import("js/crypto.zig");
const url_native = @import("js/url.zig");
const child_process_native = @import("js/child_process.zig");

pub const max_module_bytes = 16 * 1024 * 1024;

pub const Builtin = struct {
    name: []const u8,
    source: []const u8,
    native: bool = false,
};

pub const builtin_list = [_]Builtin{
    .{ .name = "node:_encoding", .source = "", .native = true },
    .{ .name = "node:buffer", .source = @embedFile("builtins/buffer.js") },
    .{ .name = "node:util", .source = @embedFile("builtins/util.js") },
    .{ .name = "node:_fs", .source = "", .native = true },
    .{ .name = "node:fs", .source = @embedFile("builtins/fs.js") },
    .{ .name = "node:fs/promises", .source = @embedFile("builtins/fs_promises.js") },
    .{ .name = "node:path", .source = @embedFile("builtins/path.js") },
    .{ .name = "node:_process", .source = "", .native = true },
    .{ .name = "node:process", .source = @embedFile("builtins/process.js") },
    .{ .name = "node:os", .source = @embedFile("builtins/os.js") },
    .{ .name = "node:_crypto", .source = "", .native = true },
    .{ .name = "node:crypto", .source = @embedFile("builtins/crypto.js") },
    .{ .name = "node:_url", .source = "", .native = true },
    .{ .name = "node:url", .source = @embedFile("builtins/url.js") },
    .{ .name = "node:events", .source = @embedFile("builtins/events.js") },
    .{ .name = "node:_child_process", .source = "", .native = true },
    .{ .name = "node:child_process", .source = @embedFile("builtins/child_process.js") },
};

const probing_suffixes = [_][]const u8{ "", ".js", ".mjs", "/index.js", "/index.mjs" };

pub fn findBuiltin(name: []const u8) ?Builtin {
    for (builtin_list) |builtin| {
        if (std.mem.eql(u8, builtin.name, name)) return builtin;
    }
    return null;
}

fn isBare(spec: []const u8) bool {
    return findScheme(spec) == null and
        !std.mem.startsWith(u8, spec, "./") and
        !std.mem.startsWith(u8, spec, "../") and
        !std.mem.startsWith(u8, spec, "/") and
        !std.mem.startsWith(u8, spec, "file:") and
        !std.mem.startsWith(u8, spec, "node:");
}

fn throwOom(ctx: *quickjs.Context) void {
    _ = ctx.throwOutOfMemory();
}

/// Node-compatible error codes for module resolution failures.
pub const ErrorCode = enum {
    module_not_found,
    unknown_builtin,
    invalid_specifier,
    unsupported_scheme,

    pub fn text(self: ErrorCode) []const u8 {
        return switch (self) {
            .module_not_found => "ERR_MODULE_NOT_FOUND",
            .unknown_builtin => "ERR_UNKNOWN_BUILTIN_MODULE",
            .invalid_specifier => "ERR_INVALID_MODULE_SPECIFIER",
            .unsupported_scheme => "ERR_UNSUPPORTED_ESM_URL_SCHEME",
        };
    }
};

fn fail(
    ctx: *quickjs.Context,
    allocator: std.mem.Allocator,
    code: ErrorCode,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const msg = allocator.printSentinel(fmt, args, 0) catch {
        throwOom(ctx);
        return;
    };
    defer allocator.free(msg);

    // Dynamic `import()` surfaces this object as the rejection reason, so it
    // must be a plain Error with a Node `code` rather than a TypeError.
    const err = quickjs.Value.initError(ctx);
    if (err.isException()) {
        err.deinit(ctx);
        throwOom(ctx);
        return;
    }
    err.setPropertyStr(ctx, "code", quickjs.Value.initStringLen(ctx, code.text())) catch {};
    err.setPropertyStr(ctx, "message", quickjs.Value.initStringLen(ctx, msg)) catch {};

    const exc = err.throw(ctx);
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

    // Only embedded builtins may reach private (`node:_*`) native modules.
    if (std.mem.startsWith(u8, spec, "node:_") and findBuiltin(base) == null) {
        fail(ctx, allocator, .unknown_builtin, "Cannot import private module '{s}' from '{s}'", .{ spec, base });
        return null;
    }

    if (std.mem.startsWith(u8, spec, "node:")) {
        if (findBuiltin(spec) == null) {
            fail(ctx, allocator, .unknown_builtin, "No such built-in module: {s}", .{spec});
            return null;
        }
        return toJsCString(ctx, spec);
    }

    if (isBare(spec)) {
        const canonical = std.fmt.allocPrint(allocator, "node:{s}", .{spec}) catch {
            throwOom(ctx);
            return null;
        };
        defer allocator.free(canonical);

        if (findBuiltin(canonical) == null) {
            fail(
                ctx,
                allocator,
                .module_not_found,
                "Cannot find package '{s}' imported from {s}; npm package resolution is not supported",
                .{ spec, base },
            );
            return null;
        }
        return toJsCString(ctx, canonical);
    }

    if (std.mem.startsWith(u8, base, "node:")) {
        fail(ctx, allocator, .invalid_specifier, "Cannot resolve '{s}' from builtin '{s}'", .{ spec, base });
        return null;
    }

    // `file:` is a path, not a remote URL. Other schemes are outside the
    // supported module graph and must fail with Node's scheme error.
    const path_or_spec: []const u8 = if (std.mem.startsWith(u8, spec, "file:")) {
        const path = fileUrlToPath(allocator, spec) catch |err| {
            fail(
                ctx,
                allocator,
                .invalid_specifier,
                "Invalid file URL '{s}' imported from {s}: {s}",
                .{ spec, base, @errorName(err) },
            );
            return null;
        };
        defer allocator.free(path);
        const resolved = resolveSpecifier(host, base, path) catch |err| switch (err) {
            error.FileNotFound => {
                fail(ctx, allocator, .module_not_found, "Cannot find module '{s}' imported from {s}", .{ spec, base });
                return null;
            },
            else => {
                fail(ctx, allocator, .module_not_found, "Cannot resolve '{s}': {s}", .{ spec, @errorName(err) });
                return null;
            },
        };
        defer allocator.free(resolved);
        return toJsCString(ctx, resolved);
    } else spec;

    if (findScheme(path_or_spec)) |scheme| {
        fail(
            ctx,
            allocator,
            .unsupported_scheme,
            "Unsupported URL scheme '{s}' in '{s}' imported from {s}",
            .{ scheme, spec, base },
        );
        return null;
    }

    const spec_res: ?[]u8 = resolveSpecifier(host, base, path_or_spec) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            fail(ctx, allocator, .module_not_found, "Cannot resolve '{s}': {s}", .{ spec, @errorName(err) });
            return null;
        },
    };
    if (spec_res) |resolved| {
        defer allocator.free(resolved);
        return toJsCString(ctx, resolved);
    }
    fail(ctx, allocator, .module_not_found, "Cannot find module '{s}' imported from {s}", .{ spec, base });
    return null;
}

/// Returns the scheme for a URL-like specifier, ignoring Windows drive
/// letters and specifiers with a path separator before the colon.
fn findScheme(spec: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return null;
    if (colon == 0) return null;
    if (std.mem.indexOfAny(u8, spec[0..colon], "/\\") != null) return null;
    if (colon == 1 and std.ascii.isAlphabetic(spec[0])) return null;
    return spec[0..colon];
}

/// Converts a `file:` URL into a filesystem path. Only POSIX-style absolute
/// paths and `localhost` hosts are accepted in v1.
fn fileUrlToPath(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var rest = url["file:".len..];
    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidFileUrl;
        const host = rest[0..slash];
        if (host.len != 0 and !std.mem.eql(u8, host, "localhost")) return error.InvalidFileUrl;
        rest = rest[slash..];
    }
    if (rest.len == 0 or rest[0] != '/') return error.InvalidFileUrl;
    return percentDecode(allocator, rest);
}

fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var index: usize = 0;
    while (index < input.len) {
        if (input[index] != '%') {
            try out.append(allocator, input[index]);
            index += 1;
            continue;
        }
        if (index + 2 >= input.len) return error.InvalidFileUrl;
        const hi = std.fmt.charToDigit(input[index + 1], 16) catch return error.InvalidFileUrl;
        const lo = std.fmt.charToDigit(input[index + 2], 16) catch return error.InvalidFileUrl;
        try out.append(allocator, (hi << 4) | lo);
        index += 3;
    }
    return out.toOwnedSlice(allocator);
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
    // A directory at the exact probe path must fall through to the
    // `<path>/index.js` probes instead of being treated as a module.
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch return false;
    return stat.kind == .file;
}

pub fn load(host_opt: ?*Host, ctx: *quickjs.Context, name: [:0]const u8) ?*quickjs.ModuleDef {
    const host = host_opt orelse {
        throwOom(ctx);
        return null;
    };

    if (findBuiltin(name)) |builtin| {
        if (builtin.native) return loadNative(ctx, builtin.name);
        return compile(host, ctx, builtin.source, builtin.name);
    }
    if (std.mem.startsWith(u8, name, "node:")) {
        fail(ctx, host.allocator, .unknown_builtin, "No such built-in module: {s}", .{name});
        return null;
    }
    return loadFile(host, ctx, name);
}

fn loadNative(ctx: *quickjs.Context, name: []const u8) ?*quickjs.ModuleDef {
    const def = if (std.mem.eql(u8, name, "node:_fs"))
        fs_native.initModule(ctx)
    else if (std.mem.eql(u8, name, "node:_process"))
        process_native.initModule(ctx)
    else if (std.mem.eql(u8, name, "node:_encoding"))
        encoding_native.initModule(ctx)
    else if (std.mem.eql(u8, name, "node:_crypto"))
        crypto_native.initModule(ctx)
    else if (std.mem.eql(u8, name, "node:_url"))
        url_native.initModule(ctx)
    else if (std.mem.eql(u8, name, "node:_child_process"))
        child_process_native.initModule(ctx)
    else
        null;

    if (def == null) {
        _ = ctx.throwOutOfMemory();
        return null;
    }
    return def;
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
        fail(ctx, allocator, .module_not_found, "Cannot read module '{s}': {s}", .{ name, @errorName(err) });
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

    const def = moduleDefFromValue(value) orelse {
        _ = ctx.throwInternalError("module compilation produced no module definition");
        return null;
    };
    setImportMeta(host, ctx, def, name, isMain(host, name));
    return def;
}

/// Extracts the `JSModuleDef` pointer carried by a compiled module value.
pub fn moduleDefFromValue(value: quickjs.Value) ?*quickjs.ModuleDef {
    const raw = quickjs.c.JS_VALUE_GET_PTR(value.cval()) orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn isMain(host: *Host, name: []const u8) bool {
    const entry = host.entry orelse return false;
    return std.mem.eql(u8, name, entry);
}

/// Populates `import.meta` for a compiled module. Failures are non-fatal: a
/// missing `import.meta` degrades behaviour, it does not break loading.
pub fn setImportMeta(
    host: *Host,
    ctx: *quickjs.Context,
    def: *quickjs.ModuleDef,
    name: []const u8,
    is_main: bool,
) void {
    const allocator = host.allocator;
    const url = if (std.mem.startsWith(u8, name, "node:"))
        allocator.dupe(u8, name) catch return
    else
        std.mem.concat(allocator, u8, &.{ "file://", name }) catch return;
    defer allocator.free(url);

    const meta = def.getImportMeta(ctx);
    if (meta.isException()) {
        meta.deinit(ctx);
        return;
    }
    defer meta.deinit(ctx);

    // setPropertyStr consumes both values, including on failure.
    meta.setPropertyStr(ctx, "url", quickjs.Value.initStringLen(ctx, url)) catch {};
    meta.setPropertyStr(ctx, "main", quickjs.Value.initBool(is_main)) catch {};
}

test "normalize maps bare specifiers to node: names" {
    const rt: *quickjs.Runtime = try .init();
    defer rt.deinit();
    const ctx: *quickjs.Context = try .init(rt);
    defer ctx.deinit();

    var host: Host = undefined;
    host.allocator = std.testing.allocator;
    host.ctx = ctx;
    host.entry = null;

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
    host.entry = null;

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
    host.entry = null;

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
