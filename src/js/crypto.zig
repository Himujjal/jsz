// One-shot hashing and entropy behind `node:_crypto`. The JS facade owns
// streaming state, encoding policy and error shapes; this module only converts
// bytes so that no hash state crosses the C boundary.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("host.zig").Host;
const value_mod = @import("value.zig");

const Value = quickjs.Value;

const Algorithm = enum { md5, sha1, sha256, sha384, sha512, sha512_256 };

fn hostOf(ctx: *quickjs.Context) ?*Host {
    return ctx.getOpaque(Host) orelse {
        _ = ctx.throwInternalError("jsz host is not initialized");
        return null;
    };
}

fn argValue(args: []const quickjs.c.JSValue, index: usize) Value {
    if (index >= args.len) return .undefined;
    return Value.fromCVal(args[index]);
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
        const message = std.fmt.allocPrintSentinel(host.allocator, "The \"{s}\" argument must be of type string", .{name}, 0) catch {
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

fn parseAlgorithm(name: []const u8) ?Algorithm {
    if (std.mem.eql(u8, name, "md5")) return .md5;
    if (std.mem.eql(u8, name, "sha1")) return .sha1;
    if (std.mem.eql(u8, name, "sha256")) return .sha256;
    if (std.mem.eql(u8, name, "sha384")) return .sha384;
    if (std.mem.eql(u8, name, "sha512")) return .sha512;
    if (std.mem.eql(u8, name, "sha512-256")) return .sha512_256;
    return null;
}

fn digestLength(algorithm: Algorithm) usize {
    return switch (algorithm) {
        .md5 => std.crypto.hash.Md5.digest_length,
        .sha1 => std.crypto.hash.Sha1.digest_length,
        .sha256 => std.crypto.hash.sha2.Sha256.digest_length,
        .sha384 => std.crypto.hash.sha2.Sha384.digest_length,
        .sha512 => std.crypto.hash.sha2.Sha512.digest_length,
        .sha512_256 => std.crypto.hash.sha2.Sha512_256.digest_length,
    };
}

fn hashBytes(algorithm: Algorithm, data: []const u8, out: []u8) void {
    switch (algorithm) {
        .md5 => {
            var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
            std.crypto.hash.Md5.hash(data, &digest, .{});
            @memcpy(out[0..digest.len], &digest);
        },
        .sha1 => {
            var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
            std.crypto.hash.Sha1.hash(data, &digest, .{});
            @memcpy(out[0..digest.len], &digest);
        },
        .sha256 => {
            var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
            @memcpy(out[0..digest.len], &digest);
        },
        .sha384 => {
            var digest: [std.crypto.hash.sha2.Sha384.digest_length]u8 = undefined;
            std.crypto.hash.sha2.Sha384.hash(data, &digest, .{});
            @memcpy(out[0..digest.len], &digest);
        },
        .sha512 => {
            var digest: [std.crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
            std.crypto.hash.sha2.Sha512.hash(data, &digest, .{});
            @memcpy(out[0..digest.len], &digest);
        },
        .sha512_256 => {
            var digest: [std.crypto.hash.sha2.Sha512_256.digest_length]u8 = undefined;
            std.crypto.hash.sha2.Sha512_256.hash(data, &digest, .{});
            @memcpy(out[0..digest.len], &digest);
        },
    }
}

fn hmacDigest(
    comptime Hmac: type,
    key: []const u8,
    data: []const u8,
    out: []u8,
) void {
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, data, key);
    @memcpy(out[0..mac.len], &mac);
}

fn hmacBytes(algorithm: Algorithm, key: []const u8, data: []const u8, out: []u8) void {
    switch (algorithm) {
        .md5 => hmacDigest(std.crypto.auth.hmac.HmacMd5, key, data, out),
        .sha1 => hmacDigest(std.crypto.auth.hmac.HmacSha1, key, data, out),
        .sha256 => hmacDigest(std.crypto.auth.hmac.sha2.HmacSha256, key, data, out),
        .sha384 => hmacDigest(std.crypto.auth.hmac.sha2.HmacSha384, key, data, out),
        .sha512 => hmacDigest(std.crypto.auth.hmac.sha2.HmacSha512, key, data, out),
        .sha512_256 => hmacDigest(
            std.crypto.auth.hmac.Hmac(std.crypto.hash.sha2.Sha512_256),
            key,
            data,
            out,
        ),
    }
}

/// `hash(algorithm, data)`; null means "unknown algorithm" for the JS facade.
fn hashFunction(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const name = argString(host, ctx, args, 0, "algorithm") orelse return .undefined;
    defer host.allocator.free(name);
    const algorithm = parseAlgorithm(name) orelse return .null;

    const data = value_mod.toBytes(host, ctx, argValue(args, 1), "data") orelse return .undefined;
    defer host.allocator.free(data);

    const length = digestLength(algorithm);
    var digest: [std.crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
    hashBytes(algorithm, data, digest[0..length]);
    return value_mod.fromBytes(ctx, digest[0..length]);
}

/// `hmac(algorithm, key, data)`; null means "unknown algorithm".
fn hmacFunction(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const name = argString(host, ctx, args, 0, "algorithm") orelse return .undefined;
    defer host.allocator.free(name);
    const algorithm = parseAlgorithm(name) orelse return .null;

    const key = value_mod.toBytes(host, ctx, argValue(args, 1), "key") orelse return .undefined;
    defer host.allocator.free(key);

    const data = value_mod.toBytes(host, ctx, argValue(args, 2), "data") orelse return .undefined;
    defer host.allocator.free(data);

    const length = digestLength(algorithm);
    var digest: [std.crypto.hash.sha2.Sha512.digest_length]u8 = undefined;
    hmacBytes(algorithm, key, data, digest[0..length]);
    return value_mod.fromBytes(ctx, digest[0..length]);
}

fn randomBytesFunction(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const size_value = argValue(args, 0);
    if (!size_value.isNumber()) {
        _ = ctx.throwTypeError("The \"size\" argument must be of type number");
        return .undefined;
    }

    const count = size_value.toInt64(ctx) catch {
        _ = ctx.throwRangeError("The value of \"size\" is out of range");
        return .undefined;
    };
    if (count < 0 or count > std.math.maxInt(i32)) {
        _ = ctx.throwRangeError("The value of \"size\" is out of range");
        return .undefined;
    }

    const buffer = host.allocator.alloc(u8, @intCast(count)) catch return ctx.throwOutOfMemory();
    defer host.allocator.free(buffer);

    std.Io.randomSecure(host.io, buffer) catch {
        _ = ctx.throwInternalError("failed to obtain secure random bytes");
        return .undefined;
    };
    return value_mod.fromBytes(ctx, buffer);
}

/// Constant-time comparison over 16-byte blocks; length is checked by the JS
/// facade so a mismatch never reaches this function.
fn timingSafeEqualFunction(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const left = value_mod.toBytes(host, ctx, argValue(args, 0), "buf1") orelse return .undefined;
    defer host.allocator.free(left);
    const right = value_mod.toBytes(host, ctx, argValue(args, 1), "buf2") orelse return .undefined;
    defer host.allocator.free(right);

    if (left.len != right.len) return Value.initBool(false);

    var mismatch: u8 = 0;
    var index: usize = 0;
    while (index < left.len) : (index += 16) {
        const take = @min(@as(usize, 16), left.len - index);
        var left_block = std.mem.zeroes([16]u8);
        var right_block = std.mem.zeroes([16]u8);
        @memcpy(left_block[0..take], left[index..][0..take]);
        @memcpy(right_block[0..take], right[index..][0..take]);
        if (!std.crypto.timing_safe.eql([16]u8, left_block, right_block)) mismatch |= 1;
    }
    return Value.initBool(mismatch == 0);
}

const Export = struct {
    name: [:0]const u8,
    func: quickjs.cfunc.Func,
    nargs: i32,
};

const module_exports = [_]Export{
    .{ .name = "hash", .func = hashFunction, .nargs = 2 },
    .{ .name = "hmac", .func = hmacFunction, .nargs = 3 },
    .{ .name = "randomBytes", .func = randomBytesFunction, .nargs = 1 },
    .{ .name = "timingSafeEqual", .func = timingSafeEqualFunction, .nargs = 2 },
};

fn moduleInit(ctx: *quickjs.Context, def: *quickjs.ModuleDef) bool {
    inline for (module_exports) |entry| {
        const function = Value.initCFunction(ctx, entry.func, entry.name, entry.nargs);
        if (!def.setExport(ctx, entry.name, function)) return false;
    }
    return true;
}

pub fn initModule(ctx: *quickjs.Context) ?*quickjs.ModuleDef {
    const def = quickjs.ModuleDef.init(ctx, "node:_crypto", moduleInit) orelse return null;
    inline for (module_exports) |entry| {
        _ = def.addExport(ctx, entry.name);
    }
    return def;
}
