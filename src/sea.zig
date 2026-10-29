//! Single-executable payloads: a `jszc`-produced binary is a copy of the
//! normal `jsz` executable followed by one payload and a fixed-size footer.
//! Detection reads the footer from the end of the running executable, so the
//! runtime never needs a sidecar file.

const std = @import("std");
const builtin = @import("builtin");

pub const footer_magic = "JSZSEA\x00\x01";
pub const payload_magic = "JSZPAY\x00\x02";
pub const footer_len = 64;
pub const header_len = 32;
pub const footer_version: u16 = 1;
pub const payload_version: u16 = 2;
pub const max_payload_bytes: u64 = 64 * 1024 * 1024;
pub const flag_desktop: u16 = 1;

pub const Asset = struct {
    /// Logical runtime name, using `/` separators.
    key: []const u8,
    data: []const u8,
};

pub const Footer = struct {
    payload_len: u64,
    digest: [32]u8,
};

/// Slices `buffer`, which owns the name, source, and assets.
pub const Payload = struct {
    buffer: []u8,
    assets: []Asset,
    name: []const u8,
    source: []const u8,
    desktop: bool,

    pub fn deinit(self: Payload, allocator: std.mem.Allocator) void {
        allocator.free(self.assets);
        allocator.free(self.buffer);
    }
};

pub fn encodeFooter(footer: Footer) [footer_len]u8 {
    var out: [footer_len]u8 = @splat(0);
    @memcpy(out[0..footer_magic.len], footer_magic);
    std.mem.writeInt(u32, out[8..12], footer_version, .little);
    std.mem.writeInt(u32, out[12..16], 0, .little);
    std.mem.writeInt(u64, out[16..24], footer.payload_len, .little);
    @memcpy(out[24..56], &footer.digest);
    return out;
}

fn decodeFooter(bytes: *const [footer_len]u8) ?Footer {
    if (!std.mem.eql(u8, bytes[0..footer_magic.len], footer_magic)) return null;
    const version = std.mem.readInt(u32, bytes[8..12], .little);
    if (version != footer_version) return null;
    const payload_len = std.mem.readInt(u64, bytes[16..24], .little);
    return .{ .payload_len = payload_len, .digest = bytes[24..56].* };
}

pub const BuildOptions = struct {
    name: []const u8,
    source: []const u8,
    assets: []const Asset = &.{},
    desktop: bool = false,
};

/// Builds `header | name | source | asset table`.
pub fn buildPayload(
    allocator: std.mem.Allocator,
    options: BuildOptions,
) ![]u8 {
    if (options.name.len > std.math.maxInt(u32)) return error.NameTooLong;
    if (options.assets.len > std.math.maxInt(u32)) return error.TooManyAssets;

    var total: u64 = header_len + options.name.len + options.source.len;
    for (options.assets) |asset| {
        if (!isValidKey(asset.key)) return error.InvalidAssetKey;
        if (asset.key.len > std.math.maxInt(u32)) return error.AssetKeyTooLong;
        total = std.math.add(u64, total, 12 + asset.key.len + asset.data.len) catch
            return error.PayloadTooLarge;
    }
    if (total > max_payload_bytes) return error.PayloadTooLarge;

    const buffer = try allocator.alloc(u8, @intCast(total));
    errdefer allocator.free(buffer);

    @memcpy(buffer[0..payload_magic.len], payload_magic);
    std.mem.writeInt(u16, buffer[8..10], payload_version, .little);
    std.mem.writeInt(u16, buffer[10..12], if (options.desktop) flag_desktop else 0, .little);
    std.mem.writeInt(u32, buffer[12..16], @intCast(options.name.len), .little);
    std.mem.writeInt(u32, buffer[16..20], @intCast(options.assets.len), .little);
    std.mem.writeInt(u64, buffer[20..28], options.source.len, .little);
    std.mem.writeInt(u32, buffer[28..32], 0, .little);

    var offset: usize = header_len;
    @memcpy(buffer[offset .. offset + options.name.len], options.name);
    offset += options.name.len;
    @memcpy(buffer[offset .. offset + options.source.len], options.source);
    offset += options.source.len;

    for (options.assets) |asset| {
        std.mem.writeInt(u32, buffer[offset..][0..4], @intCast(asset.key.len), .little);
        std.mem.writeInt(u64, buffer[offset..][4..12], asset.data.len, .little);
        offset += 12;
        @memcpy(buffer[offset .. offset + asset.key.len], asset.key);
        offset += asset.key.len;
        @memcpy(buffer[offset .. offset + asset.data.len], asset.data);
        offset += asset.data.len;
    }

    return buffer;
}

/// Takes ownership of `buffer` only on success.
pub fn parsePayload(allocator: std.mem.Allocator, buffer: []u8) !Payload {
    if (buffer.len < header_len) return error.InvalidPayload;
    if (!std.mem.eql(u8, buffer[0..payload_magic.len], payload_magic)) {
        return error.InvalidPayload;
    }
    const version = std.mem.readInt(u16, buffer[8..10], .little);
    if (version != payload_version) return error.InvalidPayload;
    const flags = std.mem.readInt(u16, buffer[10..12], .little);

    const name_len: usize = std.mem.readInt(u32, buffer[12..16], .little);
    const asset_count: usize = std.mem.readInt(u32, buffer[16..20], .little);
    const source_len_u64 = std.mem.readInt(u64, buffer[20..28], .little);
    if (source_len_u64 > buffer.len) return error.InvalidPayload;
    const source_len: usize = @intCast(source_len_u64);

    var offset = std.math.add(usize, header_len + name_len, source_len) catch
        return error.InvalidPayload;
    if (offset > buffer.len) return error.InvalidPayload;
    // Leave room for the per-asset fixed-size prefixes.
    if (asset_count > (buffer.len - offset) / 12) return error.InvalidPayload;

    const assets = try allocator.alloc(Asset, asset_count);
    errdefer allocator.free(assets);
    for (assets) |*asset| {
        if (offset + 12 > buffer.len) return error.InvalidPayload;
        const key_len: usize = std.mem.readInt(u32, buffer[offset..][0..4], .little);
        const data_len_u64 = std.mem.readInt(u64, buffer[offset..][4..12], .little);
        offset += 12;
        if (data_len_u64 > buffer.len - offset) return error.InvalidPayload;
        const data_len: usize = @intCast(data_len_u64);
        if (key_len > buffer.len - offset) return error.InvalidPayload;
        const key = buffer[offset .. offset + key_len];
        if (!isValidKey(key)) return error.InvalidPayload;
        offset += key_len;
        if (data_len > buffer.len - offset) return error.InvalidPayload;
        asset.* = .{ .key = key, .data = buffer[offset .. offset + data_len] };
        offset += data_len;
    }
    if (offset != buffer.len) return error.InvalidPayload;

    return .{
        .buffer = buffer,
        .assets = assets,
        .name = buffer[header_len .. header_len + name_len],
        .source = buffer[header_len + name_len .. header_len + name_len + source_len],
        .desktop = flags & flag_desktop != 0,
    };
}

/// Reads the payload from the currently running executable. Returns null when
/// the executable has no footer, which is the normal `jsz` case.
pub fn readSelf(allocator: std.mem.Allocator, io: std.Io) !?Payload {
    const exe = std.process.executablePathAlloc(io, allocator) catch return null;
    defer allocator.free(exe);
    return readFromFile(allocator, io, exe);
}

pub fn readFromFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !?Payload {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    const stat = file.stat(io) catch return null;
    if (stat.size < footer_len + header_len) return null;

    var footer_bytes: [footer_len]u8 = undefined;
    const got = try file.readPositionalAll(io, &footer_bytes, stat.size - footer_len);
    if (got != footer_len) return null;

    const footer = decodeFooter(&footer_bytes) orelse return null;
    if (footer.payload_len < header_len) return error.CorruptPayload;
    if (footer.payload_len > max_payload_bytes) return error.CorruptPayload;
    if (footer.payload_len > stat.size - footer_len) return error.CorruptPayload;

    const start = stat.size - footer_len - footer.payload_len;
    const buffer = try allocator.alloc(u8, @intCast(footer.payload_len));
    errdefer allocator.free(buffer);

    const read = try file.readPositionalAll(io, buffer, start);
    if (read != buffer.len) return error.CorruptPayload;

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(buffer, &digest, .{});
    if (!std.mem.eql(u8, &digest, &footer.digest)) return error.CorruptPayload;

    const payload = try parsePayload(allocator, buffer);
    return payload;
}

/// Asset keys are relative POSIX paths. They must not escape the extraction
/// root or reference the current directory.
pub fn isValidKey(key: []const u8) bool {
    if (key.len == 0) return false;
    if (key[0] == '/' or key[0] == '\\') return false;
    if (std.mem.indexOfScalar(u8, key, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, key, 0) != null) return false;

    var parts = std.mem.splitScalar(u8, key, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// Returns `key` with leading `./` segments removed, or null when invalid.
pub fn cleanKey(key: []const u8) ?[]const u8 {
    var rest = key;
    while (std.mem.startsWith(u8, rest, "./")) rest = rest[2..];
    if (!isValidKey(rest)) return null;
    return rest;
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    assets: []const Asset,
    environ: *const std.process.Environ.Map,
    root: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        assets: []const Asset,
        environ: *const std.process.Environ.Map,
    ) Store {
        return .{
            .allocator = allocator,
            .io = io,
            .assets = assets,
            .environ = environ,
        };
    }

    pub fn deinit(self: *Store) void {
        if (self.root) |root| {
            std.Io.Dir.cwd().deleteTree(self.io, root) catch {};
            self.allocator.free(root);
            self.root = null;
        }
    }

    /// Finds an asset by exact key, or by a path suffix on a component
    /// boundary. The suffix rule lets apps use `join(here, "preload.mjs")`
    /// against `import.meta.url` without knowing they were compiled.
    pub fn find(self: *const Store, path: []const u8) ?Asset {
        if (cleanKey(path)) |key| {
            for (self.assets) |asset| {
                if (std.mem.eql(u8, asset.key, key)) return asset;
            }
        }

        var best: ?Asset = null;
        for (self.assets) |asset| {
            if (!hasPathSuffix(path, asset.key)) continue;
            if (best == null or asset.key.len > best.?.key.len) best = asset;
        }
        return best;
    }

    /// Extracts assets once and returns the path for `path`, or null when no
    /// asset matches.
    pub fn resolvePath(self: *Store, path: []const u8) !?[]u8 {
        const asset = self.find(path) orelse return null;
        const root = try self.materialize();
        const joined = try std.fs.path.join(self.allocator, &.{ root, asset.key });
        return joined;
    }

    fn materialize(self: *Store) ![]const u8 {
        if (self.root) |root| return root;

        const base = self.environ.get("TMPDIR") orelse
            self.environ.get("TEMP") orelse
            self.environ.get("TMP") orelse
            if (builtin.os.tag == .windows) "." else "/tmp";

        var random: [8]u8 = undefined;
        self.io.random(&random);
        const root = try std.fmt.allocPrint(
            self.allocator,
            "{s}{c}jsz-sea-{x}",
            .{ base, std.fs.path.sep, std.mem.readInt(u64, &random, .little) },
        );
        errdefer self.allocator.free(root);

        try std.Io.Dir.cwd().createDirPath(self.io, root);
        errdefer std.Io.Dir.cwd().deleteTree(self.io, root) catch {};

        for (self.assets) |asset| {
            const dest = try std.fs.path.join(self.allocator, &.{ root, asset.key });
            defer self.allocator.free(dest);
            if (std.fs.path.dirname(dest)) |dir| {
                try std.Io.Dir.cwd().createDirPath(self.io, dir);
            }
            var file = try std.Io.Dir.cwd().createFile(self.io, dest, .{ .truncate = true });
            defer file.close(self.io);
            try file.writeStreamingAll(self.io, asset.data);
        }

        self.root = root;
        return root;
    }
};

fn hasPathSuffix(path: []const u8, key: []const u8) bool {
    if (path.len < key.len) return false;
    if (!std.mem.eql(u8, path[path.len - key.len ..], key)) return false;
    if (path.len == key.len) return true;
    const separator = path[path.len - key.len - 1];
    return separator == '/' or separator == '\\';
}

test "payload round trip with assets" {
    const allocator = std.testing.allocator;
    const assets = [_]Asset{
        .{ .key = "preload.mjs", .data = "export {};" },
        .{ .key = "ui/index.html", .data = "<html></html>" },
    };
    const buffer = try buildPayload(allocator, .{
        .name = "main.mjs",
        .source = "console.log(1);",
        .assets = &assets,
        .desktop = true,
    });
    const payload = try parsePayload(allocator, buffer);
    defer payload.deinit(allocator);

    try std.testing.expectEqualStrings("main.mjs", payload.name);
    try std.testing.expectEqualStrings("console.log(1);", payload.source);
    try std.testing.expect(payload.desktop);
    try std.testing.expectEqual(@as(usize, 2), payload.assets.len);
    try std.testing.expectEqualStrings("preload.mjs", payload.assets[0].key);
    try std.testing.expectEqualStrings("export {};", payload.assets[0].data);
    try std.testing.expectEqualStrings("ui/index.html", payload.assets[1].key);
}

test "payload rejects traversal keys" {
    const allocator = std.testing.allocator;
    const assets = [_]Asset{.{ .key = "../escape", .data = "x" }};
    try std.testing.expectError(error.InvalidAssetKey, buildPayload(allocator, .{
        .name = "a.js",
        .source = "1",
        .assets = &assets,
    }));
}

test "payload rejects trailing bytes" {
    const allocator = std.testing.allocator;
    const buffer = try buildPayload(allocator, .{ .name = "a.js", .source = "1" });
    try std.testing.expectError(
        error.InvalidPayload,
        parsePayload(allocator, buffer[0 .. buffer.len - 1]),
    );
}

test "footer round trip" {
    var digest: [32]u8 = @splat(0xab);
    digest[0] = 1;
    const encoded = encodeFooter(.{ .payload_len = 4096, .digest = digest });
    const decoded = decodeFooter(&encoded) orelse return error.FooterMissing;
    try std.testing.expectEqual(@as(u64, 4096), decoded.payload_len);
    try std.testing.expectEqualSlices(u8, &digest, &decoded.digest);
}

test "footer ignores foreign bytes" {
    var encoded: [footer_len]u8 = @splat(0xff);
    try std.testing.expect(decodeFooter(&encoded) == null);
}

test "store finds exact and suffix keys" {
    const assets = [_]Asset{
        .{ .key = "preload.mjs", .data = "" },
        .{ .key = "ui/index.html", .data = "" },
    };
    var environ: std.process.Environ.Map = undefined;
    var store = Store.init(std.testing.allocator, std.testing.io, &assets, &environ);
    defer store.deinit();

    try std.testing.expectEqualStrings("preload.mjs", store.find("preload.mjs").?.key);
    try std.testing.expectEqualStrings("preload.mjs", store.find("./preload.mjs").?.key);
    try std.testing.expectEqualStrings("preload.mjs", store.find("/opt/app/preload.mjs").?.key);
    try std.testing.expectEqualStrings("ui/index.html", store.find("/opt/app/ui/index.html").?.key);
    try std.testing.expect(store.find("other.mjs") == null);
    try std.testing.expect(store.find("/opt/app/mypreload.mjs") == null);
}
