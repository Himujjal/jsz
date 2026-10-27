// Byte codecs behind `node:_encoding`. Every export is a pure function over
// plain values: string policies and errors live in `builtins/buffer.js`.

const std = @import("std");
const quickjs = @import("quickjs");
const Host = @import("host.zig").Host;
const value_mod = @import("value.zig");

const Value = quickjs.Value;

const replacement = std.unicode.replacement_character_utf8;

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

/// Walks UTF-8 (including WTF-8 surrogate halves) one code point at a time.
/// Malformed input yields U+FFFD and advances a single byte.
const Utf8Codepoints = struct {
    bytes: []const u8,
    index: usize = 0,

    fn next(self: *Utf8Codepoints) ?u21 {
        if (self.index >= self.bytes.len) return null;
        const first = self.bytes[self.index];
        const len = std.unicode.utf8ByteSequenceLength(first) catch {
            self.index += 1;
            return 0xFFFD;
        };
        if (self.index + len > self.bytes.len) {
            self.index += 1;
            return 0xFFFD;
        }
        const seq = self.bytes[self.index..];
        const codepoint: ?u21 = switch (len) {
            1 => @as(u21, first),
            2 => std.unicode.utf8Decode2(seq[0..2].*) catch null,
            3 => std.unicode.utf8Decode3AllowSurrogateHalf(seq[0..3].*) catch null,
            4 => std.unicode.utf8Decode4(seq[0..4].*) catch null,
            else => null,
        };
        if (codepoint) |cp| {
            self.index += len;
            return cp;
        }
        self.index += 1;
        return 0xFFFD;
    }
};

fn appendCodepoint(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    cp: u21,
) !void {
    var buffer: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buffer) catch return;
    try out.appendSlice(allocator, buffer[0..len]);
}

fn appendUtf16Le(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    unit: u16,
) !void {
    try out.append(allocator, @truncate(unit));
    try out.append(allocator, @truncate(unit >> 8));
}

fn appendSurrogates(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    cp: u21,
) !void {
    const value = cp - 0x10000;
    const high: u16 = @intCast(0xD800 + (value >> 10));
    const low: u16 = @intCast(0xDC00 + (value & 0x3FF));
    try appendUtf16Le(allocator, out, high);
    try appendUtf16Le(allocator, out, low);
}

/// Encodes every UTF-16 code unit of `text` down to its low `mask` bits.
fn encodeCodeUnitBytes(
    allocator: std.mem.Allocator,
    text: []const u8,
    comptime mask: u21,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var codepoints: Utf8Codepoints = .{ .bytes = text };
    while (codepoints.next()) |cp| {
        if (cp >= 0x10000) {
            const value = cp - 0x10000;
            try out.append(allocator, @truncate((0xD800 + (value >> 10)) & mask));
            try out.append(allocator, @truncate((0xDC00 + (value & 0x3FF)) & mask));
        } else {
            try out.append(allocator, @truncate(cp & mask));
        }
    }
    return out.toOwnedSlice(allocator);
}

fn decodeBytesToString(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    comptime transform: fn (u8) u21,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (bytes) |byte| try appendCodepoint(allocator, &out, transform(byte));
    return out.toOwnedSlice(allocator);
}

fn identityCodepoint(byte: u8) u21 {
    return byte;
}

fn asciiCodepoint(byte: u8) u21 {
    return byte & 0x7f;
}

fn utf8Encode(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const text = argString(host, ctx, args, 0, "str") orelse return .undefined;
    defer host.allocator.free(text);

    return value_mod.fromBytes(ctx, text);
}

fn utf8Decode(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const bytes = value_mod.toBytes(host, ctx, argValue(args, 0), "bytes") orelse return .undefined;
    defer host.allocator.free(bytes);

    // QuickJS needs valid UTF-8, so malformed input is replaced up front.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(host.allocator);
    var index: usize = 0;
    while (index < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch {
            out.appendSlice(host.allocator, &replacement) catch return ctx.throwOutOfMemory();
            index += 1;
            continue;
        };
        if (index + len > bytes.len) {
            out.appendSlice(host.allocator, &replacement) catch return ctx.throwOutOfMemory();
            index += 1;
            continue;
        }
        const seq = bytes[index .. index + len];
        if (std.unicode.utf8ValidateSlice(seq)) {
            out.appendSlice(host.allocator, seq) catch return ctx.throwOutOfMemory();
            index += len;
        } else {
            out.appendSlice(host.allocator, &replacement) catch return ctx.throwOutOfMemory();
            index += 1;
        }
    }

    return value_mod.fromUtf8(ctx, out.items);
}

fn utf8IsValid(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const bytes = value_mod.toBytes(host, ctx, argValue(args, 0), "bytes") orelse return .undefined;
    defer host.allocator.free(bytes);

    return Value.initBool(std.unicode.utf8ValidateSlice(bytes));
}

fn latin1Encode(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const text = argString(host, ctx, args, 0, "str") orelse return .undefined;
    defer host.allocator.free(text);

    const bytes = encodeCodeUnitBytes(host.allocator, text, 0xFF) catch return ctx.throwOutOfMemory();
    defer host.allocator.free(bytes);
    return value_mod.fromBytes(ctx, bytes);
}

fn latin1Decode(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const bytes = value_mod.toBytes(host, ctx, argValue(args, 0), "bytes") orelse return .undefined;
    defer host.allocator.free(bytes);

    const text = decodeBytesToString(host.allocator, bytes, identityCodepoint) catch return ctx.throwOutOfMemory();
    defer host.allocator.free(text);
    return value_mod.fromUtf8(ctx, text);
}

fn asciiEncode(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const text = argString(host, ctx, args, 0, "str") orelse return .undefined;
    defer host.allocator.free(text);

    // Node writes the low 8 bits for 'ascii' too; only asciiDecode masks.
    const bytes = encodeCodeUnitBytes(host.allocator, text, 0xFF) catch return ctx.throwOutOfMemory();
    defer host.allocator.free(bytes);
    return value_mod.fromBytes(ctx, bytes);
}

fn asciiDecode(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const bytes = value_mod.toBytes(host, ctx, argValue(args, 0), "bytes") orelse return .undefined;
    defer host.allocator.free(bytes);

    const text = decodeBytesToString(host.allocator, bytes, asciiCodepoint) catch return ctx.throwOutOfMemory();
    defer host.allocator.free(text);
    return value_mod.fromUtf8(ctx, text);
}

fn utf16leEncode(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const text = argString(host, ctx, args, 0, "str") orelse return .undefined;
    defer host.allocator.free(text);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(host.allocator);
    var codepoints: Utf8Codepoints = .{ .bytes = text };
    while (codepoints.next()) |cp| {
        if (cp >= 0x10000) {
            appendSurrogates(host.allocator, &out, cp) catch return ctx.throwOutOfMemory();
        } else {
            appendUtf16Le(host.allocator, &out, @intCast(cp)) catch return ctx.throwOutOfMemory();
        }
    }

    return value_mod.fromBytes(ctx, out.items);
}

fn utf16leDecode(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const bytes = value_mod.toBytes(host, ctx, argValue(args, 0), "bytes") orelse return .undefined;
    defer host.allocator.free(bytes);

    // Byte slicing cannot reinterpret as u16: alignment is not guaranteed.
    const count = bytes.len / 2;
    const units = host.allocator.alloc(u16, count) catch return ctx.throwOutOfMemory();
    defer host.allocator.free(units);
    for (units, 0..) |*unit, index| {
        unit.* = @as(u16, bytes[index * 2]) | (@as(u16, bytes[index * 2 + 1]) << 8);
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(host.allocator);
    var index: usize = 0;
    while (index < units.len) {
        const unit = units[index];
        if (std.unicode.utf16IsHighSurrogate(unit) and
            index + 1 < units.len and
            std.unicode.utf16IsLowSurrogate(units[index + 1]))
        {
            const cp = std.unicode.utf16DecodeSurrogatePair(units[index..][0..2]) catch 0xFFFD;
            appendCodepoint(host.allocator, &out, cp) catch return ctx.throwOutOfMemory();
            index += 2;
            continue;
        }
        if (std.unicode.isSurrogateCodepoint(unit)) {
            out.appendSlice(host.allocator, &replacement) catch return ctx.throwOutOfMemory();
            index += 1;
            continue;
        }
        appendCodepoint(host.allocator, &out, unit) catch return ctx.throwOutOfMemory();
        index += 1;
    }

    return value_mod.fromUtf8(ctx, out.items);
}

fn hexEncode(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const bytes = value_mod.toBytes(host, ctx, argValue(args, 0), "bytes") orelse return .undefined;
    defer host.allocator.free(bytes);

    const digits = "0123456789abcdef";
    const text = host.allocator.alloc(u8, bytes.len * 2) catch return ctx.throwOutOfMemory();
    defer host.allocator.free(text);
    for (bytes, 0..) |byte, index| {
        text[index * 2] = digits[byte >> 4];
        text[index * 2 + 1] = digits[byte & 0x0f];
    }

    return value_mod.fromUtf8(ctx, text);
}

fn hexValue(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn hexDecode(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const text = argString(host, ctx, args, 0, "str") orelse return .undefined;
    defer host.allocator.free(text);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(host.allocator);
    var index: usize = 0;
    while (index + 1 < text.len) : (index += 2) {
        const high = hexValue(text[index]) orelse break;
        const low = hexValue(text[index + 1]) orelse break;
        out.append(host.allocator, (high << 4) | low) catch return ctx.throwOutOfMemory();
    }

    return value_mod.fromBytes(ctx, out.items);
}

const Base64Kind = enum { standard, url_safe };

/// Node forgives stray characters, missing padding and swapped alphabets, so
/// everything outside the alphabet is dropped before decoding.
fn base64Decode(
    allocator: std.mem.Allocator,
    text: []const u8,
    comptime kind: Base64Kind,
) ![]const u8 {
    const urlsafe = kind == .url_safe;
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte == '=') break;
        switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9' => try scratch.append(allocator, byte),
            '+' => try scratch.append(allocator, if (urlsafe) '-' else '+'),
            '/' => try scratch.append(allocator, if (urlsafe) '_' else '/'),
            '-' => try scratch.append(allocator, if (urlsafe) '-' else '+'),
            '_' => try scratch.append(allocator, if (urlsafe) '_' else '/'),
            else => {},
        }
    }

    if (scratch.items.len % 4 == 1) _ = scratch.pop();

    const decoder = switch (kind) {
        .standard => &std.base64.standard_no_pad.Decoder,
        .url_safe => &std.base64.url_safe_no_pad.Decoder,
    };
    const size = decoder.calcSizeUpperBound(scratch.items.len) catch return &.{};
    const out = try allocator.alloc(u8, size);
    decoder.decode(out, scratch.items) catch {
        allocator.free(out);
        return &.{};
    };
    return out;
}

fn base64EncodeBytes(
    host: *Host,
    ctx: *quickjs.Context,
    bytes: []const u8,
    comptime padded: bool,
    comptime urlsafe: bool,
) Value {
    const encoder = if (urlsafe)
        (if (padded) &std.base64.url_safe.Encoder else &std.base64.url_safe_no_pad.Encoder)
    else
        (if (padded) &std.base64.standard.Encoder else &std.base64.standard_no_pad.Encoder);

    const size = encoder.calcSize(bytes.len);
    const out = host.allocator.alloc(u8, size) catch return ctx.throwOutOfMemory();
    defer host.allocator.free(out);
    return value_mod.fromUtf8(ctx, encoder.encode(out, bytes));
}

fn base64Encode(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const bytes = value_mod.toBytes(host, ctx, argValue(args, 0), "bytes") orelse return .undefined;
    defer host.allocator.free(bytes);

    return base64EncodeBytes(host, ctx, bytes, true, false);
}

fn base64DecodeExport(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const text = argString(host, ctx, args, 0, "str") orelse return .undefined;
    defer host.allocator.free(text);

    const bytes = base64Decode(host.allocator, text, .standard) catch return ctx.throwOutOfMemory();
    defer host.allocator.free(bytes);
    return value_mod.fromBytes(ctx, bytes);
}

fn base64urlEncode(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const bytes = value_mod.toBytes(host, ctx, argValue(args, 0), "bytes") orelse return .undefined;
    defer host.allocator.free(bytes);

    return base64EncodeBytes(host, ctx, bytes, false, true);
}

fn base64urlDecode(ctx_opt: ?*quickjs.Context, _: Value, args: []const quickjs.c.JSValue) Value {
    const ctx = ctx_opt orelse return .undefined;
    const host = hostOf(ctx) orelse return .undefined;

    const text = argString(host, ctx, args, 0, "str") orelse return .undefined;
    defer host.allocator.free(text);

    const bytes = base64Decode(host.allocator, text, .url_safe) catch return ctx.throwOutOfMemory();
    defer host.allocator.free(bytes);
    return value_mod.fromBytes(ctx, bytes);
}

const Export = struct {
    name: [:0]const u8,
    func: quickjs.cfunc.Func,
    nargs: i32,
};

const module_exports = [_]Export{
    .{ .name = "utf8Encode", .func = utf8Encode, .nargs = 1 },
    .{ .name = "utf8Decode", .func = utf8Decode, .nargs = 1 },
    .{ .name = "utf8IsValid", .func = utf8IsValid, .nargs = 1 },
    .{ .name = "latin1Encode", .func = latin1Encode, .nargs = 1 },
    .{ .name = "latin1Decode", .func = latin1Decode, .nargs = 1 },
    .{ .name = "asciiEncode", .func = asciiEncode, .nargs = 1 },
    .{ .name = "asciiDecode", .func = asciiDecode, .nargs = 1 },
    .{ .name = "utf16leEncode", .func = utf16leEncode, .nargs = 1 },
    .{ .name = "utf16leDecode", .func = utf16leDecode, .nargs = 1 },
    .{ .name = "hexEncode", .func = hexEncode, .nargs = 1 },
    .{ .name = "hexDecode", .func = hexDecode, .nargs = 1 },
    .{ .name = "base64Encode", .func = base64Encode, .nargs = 1 },
    .{ .name = "base64Decode", .func = base64DecodeExport, .nargs = 1 },
    .{ .name = "base64urlEncode", .func = base64urlEncode, .nargs = 1 },
    .{ .name = "base64urlDecode", .func = base64urlDecode, .nargs = 1 },
};

fn moduleInit(ctx: *quickjs.Context, def: *quickjs.ModuleDef) bool {
    inline for (module_exports) |entry| {
        const function = Value.initCFunction(ctx, entry.func, entry.name, entry.nargs);
        if (!def.setExport(ctx, entry.name, function)) return false;
    }
    return true;
}

pub fn initModule(ctx: *quickjs.Context) ?*quickjs.ModuleDef {
    const def = quickjs.ModuleDef.init(ctx, "node:_encoding", moduleInit) orelse return null;
    inline for (module_exports) |entry| {
        _ = def.addExport(ctx, entry.name);
    }
    return def;
}
