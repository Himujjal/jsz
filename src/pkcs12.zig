// PKCS#12 (PFX) reader.
//
// Dusty's TLS layer only accepts PEM, so this module turns a PFX into a
// concatenated certificate chain and one PKCS#8 private key. Only the parts
// Node's `pfx`/`passphrase` options need are implemented: plaintext, PBES2,
// and legacy PKCS#12 PBE (SHA-1 with 3DES or RC2) encrypted safe contents,
// cert bags, key bags, and shrouded key bags.

const std = @import("std");

pub const ParseError = error{
    /// Bytes are not a well-formed PFX structure.
    InvalidPfx,
    /// PFX is well-formed but uses an algorithm or bag this parser lacks.
    UnsupportedPfx,
    /// Decryption produced invalid padding, i.e. the passphrase is wrong.
    InvalidPassword,
    OutOfMemory,
};

pub const Bundle = struct {
    /// One or more concatenated PEM certificates.
    cert_pem: []u8,
    /// A single PEM PKCS#8 private key.
    key_pem: []u8,

    pub fn deinit(self: *Bundle, allocator: std.mem.Allocator) void {
        allocator.free(self.cert_pem);
        allocator.free(self.key_pem);
        self.* = undefined;
    }
};

/// Parse a DER-encoded PFX into PEM. MAC verification is intentionally
/// skipped; a wrong passphrase is detected by decryption padding.
pub fn parse(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    passphrase: []const u8,
) ParseError!Bundle {
    var builder: Builder = .{
        .allocator = allocator,
        .passphrase = passphrase,
    };
    defer builder.deinit();

    var pfx_reader: Reader = .{ .data = bytes };
    const pfx = try pfx_reader.read();
    if (pfx.tag != tag_sequence) return error.InvalidPfx;

    var fields: Reader = .{ .data = pfx.contents };
    const version = try fields.read();
    if (version.tag != tag_integer) return error.InvalidPfx;
    if (version.contents.len != 1 or version.contents[0] != 3) return error.InvalidPfx;

    const auth_safe = try fields.read();
    const authenticated_safe = try dataContent(auth_safe);

    var contents: Reader = .{ .data = authenticated_safe };
    const safe_sequence = try contents.read();
    if (safe_sequence.tag != tag_sequence) return error.InvalidPfx;

    try builder.parseAuthenticatedSafe(safe_sequence.raw);

    if (builder.certs.items.len == 0 or !builder.have_key) return error.InvalidPfx;

    const cert_pem = try builder.certs.toOwnedSlice(allocator);
    errdefer allocator.free(cert_pem);
    const key_pem = try builder.key.toOwnedSlice(allocator);
    return .{ .cert_pem = cert_pem, .key_pem = key_pem };
}

const Builder = struct {
    allocator: std.mem.Allocator,
    passphrase: []const u8,
    certs: std.ArrayList(u8) = .empty,
    key: std.ArrayList(u8) = .empty,
    have_key: bool = false,

    fn deinit(self: *Builder) void {
        self.certs.deinit(self.allocator);
        self.key.deinit(self.allocator);
    }

    fn parseAuthenticatedSafe(self: *Builder, data: []const u8) ParseError!void {
        var reader: Reader = .{ .data = data };
        const sequence = try reader.read();
        if (sequence.tag != tag_sequence) return error.InvalidPfx;

        var items: Reader = .{ .data = sequence.contents };
        while (!items.atEnd()) {
            const content_info = try items.read();
            const info = try parseContentInfo(content_info);

            if (oidEql(info.oid, &oid_data)) {
                const safe_contents = try explicitOctets(info.content);
                try self.parseSafeContents(safe_contents);
            } else if (oidEql(info.oid, &oid_encrypted_data)) {
                const plain = try self.decryptContentInfo(info);
                defer self.allocator.free(plain);
                try self.parseSafeContents(plain);
            } else {
                return error.UnsupportedPfx;
            }
        }
    }

    fn parseSafeContents(self: *Builder, data: []const u8) ParseError!void {
        var reader: Reader = .{ .data = data };
        const sequence = try reader.read();
        if (sequence.tag != tag_sequence) return error.InvalidPfx;

        var bags: Reader = .{ .data = sequence.contents };
        while (!bags.atEnd()) {
            const bag = try bags.read();
            try self.parseSafeBag(bag);
        }
    }

    fn parseSafeBag(self: *Builder, bag: Element) ParseError!void {
        if (bag.tag != tag_sequence) return error.InvalidPfx;

        var fields: Reader = .{ .data = bag.contents };
        const id = try fields.read();
        if (id.tag != tag_oid) return error.InvalidPfx;
        const value = try fields.read();
        if (value.tag != tag_explicit_0) return error.InvalidPfx;

        if (oidEql(id.contents, &oid_cert_bag)) {
            try self.parseCertBag(value);
        } else if (oidEql(id.contents, &oid_key_bag)) {
            try self.parseKeyBag(value);
        } else if (oidEql(id.contents, &oid_shrouded_key_bag)) {
            try self.parseShroudedKeyBag(value);
        }
        // Other bag types (CRLs, secrets, friendly-name-only bags) do not
        // contribute to a TLS listener and are ignored.
    }

    fn parseCertBag(self: *Builder, value: Element) ParseError!void {
        var outer: Reader = .{ .data = value.contents };
        const cert_bag = try outer.read();
        if (cert_bag.tag != tag_sequence) return error.InvalidPfx;

        var fields: Reader = .{ .data = cert_bag.contents };
        const cert_id = try fields.read();
        if (cert_id.tag != tag_oid) return error.InvalidPfx;
        if (!oidEql(cert_id.contents, &oid_x509_certificate)) return error.UnsupportedPfx;

        const cert_value = try fields.read();
        if (cert_value.tag != tag_explicit_0) return error.InvalidPfx;

        var inner: Reader = .{ .data = cert_value.contents };
        const der = try inner.read();
        if (der.tag != tag_octet_string) return error.InvalidPfx;

        try appendPem(&self.certs, self.allocator, "CERTIFICATE", der.contents);
    }

    fn parseKeyBag(self: *Builder, value: Element) ParseError!void {
        var inner: Reader = .{ .data = value.contents };
        const key_info = try inner.read();
        if (key_info.tag != tag_sequence) return error.InvalidPfx;

        try self.addKey(key_info.raw);
    }

    fn parseShroudedKeyBag(self: *Builder, value: Element) ParseError!void {
        var inner: Reader = .{ .data = value.contents };
        const encrypted_key_info = try inner.read();
        if (encrypted_key_info.tag != tag_sequence) return error.InvalidPfx;

        const key_der = try self.decryptEncryptedPrivateKeyInfo(encrypted_key_info);
        defer self.allocator.free(key_der);

        // A wrong passphrase that happens to pass padding validation still
        // yields bytes that are not a PKCS#8 PrivateKeyInfo.
        var check: Reader = .{ .data = key_der };
        const key_info = check.read() catch return error.InvalidPassword;
        if (key_info.tag != tag_sequence or !check.atEnd()) return error.InvalidPassword;

        try self.addKey(key_info.raw);
    }

    fn addKey(self: *Builder, key_der: []const u8) ParseError!void {
        if (self.have_key) return;
        try appendPem(&self.key, self.allocator, "PRIVATE KEY", key_der);
        self.have_key = true;
    }

    fn decryptContentInfo(self: *Builder, info: ContentInfo) ParseError![]u8 {
        var outer: Reader = .{ .data = info.content.contents };
        const encrypted_data = try outer.read();
        if (encrypted_data.tag != tag_sequence) return error.InvalidPfx;

        var fields: Reader = .{ .data = encrypted_data.contents };
        const version = try fields.read();
        if (version.tag != tag_integer) return error.InvalidPfx;

        const encrypted_content_info = try fields.read();
        if (encrypted_content_info.tag != tag_sequence) return error.InvalidPfx;

        var eci: Reader = .{ .data = encrypted_content_info.contents };
        const content_type = try eci.read();
        if (content_type.tag != tag_oid) return error.InvalidPfx;
        if (!oidEql(content_type.contents, &oid_data)) return error.UnsupportedPfx;

        const algorithm = try eci.read();
        if (algorithm.tag != tag_sequence) return error.InvalidPfx;

        const encrypted_content = try eci.read();
        if (encrypted_content.tag != tag_implicit_0) return error.InvalidPfx;

        return self.decryptWithAlgorithm(algorithm, encrypted_content.contents);
    }

    fn decryptEncryptedPrivateKeyInfo(self: *Builder, info: Element) ParseError![]u8 {
        var fields: Reader = .{ .data = info.contents };
        const algorithm = try fields.read();
        if (algorithm.tag != tag_sequence) return error.InvalidPfx;

        const encrypted = try fields.read();
        if (encrypted.tag != tag_octet_string) return error.InvalidPfx;

        return self.decryptWithAlgorithm(algorithm, encrypted.contents);
    }

    fn decryptWithAlgorithm(
        self: *Builder,
        algorithm: Element,
        ciphertext: []const u8,
    ) ParseError![]u8 {
        var alg: Reader = .{ .data = algorithm.contents };
        const algorithm_id = try alg.read();
        if (algorithm_id.tag != tag_oid) return error.InvalidPfx;

        if (oidEql(algorithm_id.contents, &oid_pbes2)) {
            return self.decryptPbes2(&alg, ciphertext);
        }
        if (legacyPbe(algorithm_id.contents)) |legacy| {
            return self.decryptLegacyPbe(legacy, &alg, ciphertext);
        }
        return error.UnsupportedPfx;
    }

    fn decryptPbes2(
        self: *Builder,
        alg: *Reader,
        ciphertext: []const u8,
    ) ParseError![]u8 {
        const params = try alg.read();
        if (params.tag != tag_sequence) return error.InvalidPfx;

        var param_fields: Reader = .{ .data = params.contents };
        const kdf = try param_fields.read();
        if (kdf.tag != tag_sequence) return error.InvalidPfx;
        const scheme = try param_fields.read();
        if (scheme.tag != tag_sequence) return error.InvalidPfx;

        // Encryption scheme first: its key size is needed by PBKDF2.
        var scheme_fields: Reader = .{ .data = scheme.contents };
        const scheme_id = try scheme_fields.read();
        if (scheme_id.tag != tag_oid) return error.InvalidPfx;
        const key_length = aesKeyLength(scheme_id.contents) orelse return error.UnsupportedPfx;

        const iv_element = try scheme_fields.read();
        if (iv_element.tag != tag_octet_string or iv_element.contents.len != 16) {
            return error.InvalidPfx;
        }
        const iv: [16]u8 = iv_element.contents[0..16].*;

        var kdf_fields: Reader = .{ .data = kdf.contents };
        const kdf_id = try kdf_fields.read();
        if (kdf_id.tag != tag_oid) return error.InvalidPfx;
        if (!oidEql(kdf_id.contents, &oid_pbkdf2)) return error.UnsupportedPfx;

        const kdf_params = try kdf_fields.read();
        if (kdf_params.tag != tag_sequence) return error.InvalidPfx;

        var pbkdf2_fields: Reader = .{ .data = kdf_params.contents };
        const salt = try pbkdf2_fields.read();
        if (salt.tag != tag_octet_string) return error.InvalidPfx;
        const iterations_element = try pbkdf2_fields.read();
        if (iterations_element.tag != tag_integer) return error.InvalidPfx;
        const iterations = try readU32(iterations_element);
        if (iterations == 0) return error.InvalidPfx;

        var prf: Prf = .sha1;
        if (!pbkdf2_fields.atEnd()) {
            const optional = try pbkdf2_fields.read();
            if (optional.tag == tag_integer) {
                const declared_length = try readU32(optional);
                if (declared_length != key_length) return error.InvalidPfx;
                if (!pbkdf2_fields.atEnd()) {
                    prf = try parsePrf(try pbkdf2_fields.read());
                }
            } else if (optional.tag == tag_sequence) {
                prf = try parsePrf(optional);
            } else {
                return error.InvalidPfx;
            }
        }

        var derived: [32]u8 = undefined;
        const key = derived[0..key_length];
        try deriveKey(prf, key, self.passphrase, salt.contents, iterations);

        return cbcDecrypt(self.allocator, ciphertext, key, iv);
    }

    fn decryptLegacyPbe(
        self: *Builder,
        legacy: LegacyPbe,
        alg: *Reader,
        ciphertext: []const u8,
    ) ParseError![]u8 {
        const params = try alg.read();
        if (params.tag != tag_sequence) return error.InvalidPfx;

        var fields: Reader = .{ .data = params.contents };
        const salt = try fields.read();
        if (salt.tag != tag_octet_string) return error.InvalidPfx;
        const iterations_element = try fields.read();
        if (iterations_element.tag != tag_integer) return error.InvalidPfx;
        const iterations = try readU32(iterations_element);
        if (iterations == 0) return error.InvalidPfx;

        var material: [32]u8 = undefined;
        const key = material[0..legacy.key_len];
        const iv = material[legacy.key_len..][0..8];
        try pkcs12Kdf(key, 1, salt.contents, self.passphrase, iterations, self.allocator);
        try pkcs12Kdf(iv, 2, salt.contents, self.passphrase, iterations, self.allocator);

        return switch (legacy.cipher) {
            .triple_des => des3CbcDecrypt(self.allocator, ciphertext, key, iv.*),
            .rc2 => rc2CbcDecrypt(self.allocator, ciphertext, key, legacy.effective_bits, iv.*),
        };
    }
};

const LegacyPbe = struct {
    cipher: enum { triple_des, rc2 },
    key_len: usize,
    effective_bits: u16,
};

fn legacyPbe(oid: []const u8) ?LegacyPbe {
    if (oidEql(oid, &oid_pbe_sha1_3des)) {
        return .{ .cipher = .triple_des, .key_len = 24, .effective_bits = 0 };
    }
    if (oidEql(oid, &oid_pbe_sha1_2des)) {
        return .{ .cipher = .triple_des, .key_len = 16, .effective_bits = 0 };
    }
    if (oidEql(oid, &oid_pbe_sha1_rc2_128)) {
        return .{ .cipher = .rc2, .key_len = 16, .effective_bits = 128 };
    }
    if (oidEql(oid, &oid_pbe_sha1_rc2_40)) {
        return .{ .cipher = .rc2, .key_len = 5, .effective_bits = 40 };
    }
    return null;
}

const Element = struct {
    tag: u8,
    contents: []const u8,
    raw: []const u8,
};

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn atEnd(self: Reader) bool {
        return self.pos >= self.data.len;
    }

    fn read(self: *Reader) ParseError!Element {
        const start = self.pos;
        if (self.pos >= self.data.len) return error.InvalidPfx;

        const tag = self.data[self.pos];
        self.pos += 1;
        // High-tag-number form is not used by PKCS#12.
        if (tag & 0x1f == 0x1f) return error.InvalidPfx;
        if (self.pos >= self.data.len) return error.InvalidPfx;

        const first = self.data[self.pos];
        self.pos += 1;

        var length: usize = 0;
        if (first & 0x80 == 0) {
            length = first;
        } else {
            const byte_count = first & 0x7f;
            // Indefinite lengths and lengths wider than usize are invalid DER.
            if (byte_count == 0 or byte_count > @sizeOf(usize)) return error.InvalidPfx;
            if (byte_count > self.data.len - self.pos) return error.InvalidPfx;
            for (self.data[self.pos .. self.pos + byte_count]) |byte| {
                if (length > (std.math.maxInt(usize) - @as(usize, byte)) / 256) return error.InvalidPfx;
                length = length * 256 + byte;
            }
            self.pos += byte_count;
        }

        if (length > self.data.len - self.pos) return error.InvalidPfx;
        const contents = self.data[self.pos .. self.pos + length];
        self.pos += length;
        return .{ .tag = tag, .contents = contents, .raw = self.data[start..self.pos] };
    }
};

const ContentInfo = struct {
    oid: []const u8,
    content: Element,
};

fn parseContentInfo(element: Element) ParseError!ContentInfo {
    if (element.tag != tag_sequence) return error.InvalidPfx;

    var fields: Reader = .{ .data = element.contents };
    const oid = try fields.read();
    if (oid.tag != tag_oid) return error.InvalidPfx;
    const content = try fields.read();
    if (content.tag != tag_explicit_0) return error.InvalidPfx;

    return .{ .oid = oid.contents, .content = content };
}

/// Returns the OCTET STRING inside a `data` ContentInfo.
fn dataContent(element: Element) ParseError![]const u8 {
    const info = try parseContentInfo(element);
    if (!oidEql(info.oid, &oid_data)) return error.InvalidPfx;
    return explicitOctets(info.content);
}

/// Returns the single element wrapped by an explicit `[0]` tag.
fn explicitOctets(content: Element) ParseError![]const u8 {
    var reader: Reader = .{ .data = content.contents };
    const octets = try reader.read();
    if (octets.tag != tag_octet_string) return error.InvalidPfx;
    return octets.contents;
}

fn readU32(element: Element) ParseError!u32 {
    if (element.contents.len == 0 or element.contents.len > 4) return error.InvalidPfx;
    var value: u32 = 0;
    for (element.contents) |byte| value = (value << 8) | byte;
    return value;
}

const Prf = enum { sha1, sha224, sha256, sha384, sha512 };

fn parsePrf(element: Element) ParseError!Prf {
    if (element.tag != tag_sequence) return error.InvalidPfx;
    var fields: Reader = .{ .data = element.contents };
    const oid = try fields.read();
    if (oid.tag != tag_oid) return error.InvalidPfx;

    if (oidEql(oid.contents, &oid_hmac_sha1)) return .sha1;
    if (oidEql(oid.contents, &oid_hmac_sha224)) return .sha224;
    if (oidEql(oid.contents, &oid_hmac_sha256)) return .sha256;
    if (oidEql(oid.contents, &oid_hmac_sha384)) return .sha384;
    if (oidEql(oid.contents, &oid_hmac_sha512)) return .sha512;
    return error.UnsupportedPfx;
}

fn deriveKey(
    prf: Prf,
    key: []u8,
    password: []const u8,
    salt: []const u8,
    iterations: u32,
) ParseError!void {
    const result = switch (prf) {
        .sha1 => std.crypto.pwhash.pbkdf2(key, password, salt, iterations, std.crypto.auth.hmac.HmacSha1),
        .sha224 => std.crypto.pwhash.pbkdf2(key, password, salt, iterations, std.crypto.auth.hmac.sha2.HmacSha224),
        .sha256 => std.crypto.pwhash.pbkdf2(key, password, salt, iterations, std.crypto.auth.hmac.sha2.HmacSha256),
        .sha384 => std.crypto.pwhash.pbkdf2(key, password, salt, iterations, std.crypto.auth.hmac.sha2.HmacSha384),
        .sha512 => std.crypto.pwhash.pbkdf2(key, password, salt, iterations, std.crypto.auth.hmac.sha2.HmacSha512),
    };
    result catch return error.InvalidPfx;
}

fn aesKeyLength(oid: []const u8) ?usize {
    if (oidEql(oid, &oid_aes128_cbc)) return 16;
    if (oidEql(oid, &oid_aes192_cbc)) return 24;
    if (oidEql(oid, &oid_aes256_cbc)) return 32;
    return null;
}

fn oidEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn cbcDecrypt(
    allocator: std.mem.Allocator,
    ciphertext: []const u8,
    key: []const u8,
    iv: [16]u8,
) ParseError![]u8 {
    if (ciphertext.len == 0 or ciphertext.len % 16 != 0) return error.InvalidPfx;

    const plain = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(plain);

    const aes = Aes.init(key);
    var previous = iv;
    var offset: usize = 0;
    while (offset < ciphertext.len) : (offset += 16) {
        const block: [16]u8 = ciphertext[offset..][0..16].*;
        const decrypted = aes.decryptBlock(&block);
        for (0..16) |index| plain[offset + index] = decrypted[index] ^ previous[index];
        previous = block;
    }

    return stripPadding(allocator, plain, 16);
}

/// Validates PKCS#7 padding for `block_size` and returns a trimmed copy.
fn stripPadding(
    allocator: std.mem.Allocator,
    plain: []u8,
    block_size: u8,
) ParseError![]u8 {
    const padding = plain[plain.len - 1];
    if (padding == 0 or padding > block_size or padding > plain.len) {
        return error.InvalidPassword;
    }
    for (plain[plain.len - padding ..]) |byte| {
        if (byte != padding) return error.InvalidPassword;
    }

    const length = plain.len - padding;
    const trimmed = try allocator.alloc(u8, length);
    @memcpy(trimmed, plain[0..length]);
    allocator.free(plain);
    return trimmed;
}

/// PKCS#12 KDF from RFC 7292 Appendix B, with SHA-1. `id` is the
/// diversifier: 1 for keys, 2 for IVs, 3 for MAC keys.
fn pkcs12Kdf(
    out: []u8,
    id: u8,
    salt: []const u8,
    passphrase: []const u8,
    iterations: u32,
    allocator: std.mem.Allocator,
) ParseError!void {
    var password: std.ArrayList(u8) = .empty;
    defer password.deinit(allocator);
    try appendBmpString(&password, allocator, passphrase);

    const v = 64;
    var diversifier: [v]u8 = undefined;
    @memset(&diversifier, id);

    const salt_len = roundUp(salt.len, v);
    const password_len = roundUp(password.items.len, v);
    const input_len = salt_len + password_len;

    const input = try allocator.alloc(u8, input_len);
    defer allocator.free(input);
    fillRepeated(input[0..salt_len], salt);
    fillRepeated(input[salt_len..], password.items);

    var offset: usize = 0;
    while (offset < out.len) {
        var digest: [20]u8 = undefined;
        var hash = std.crypto.hash.Sha1.init(.{});
        hash.update(&diversifier);
        hash.update(input);
        hash.final(&digest);
        var round: u32 = 1;
        while (round < iterations) : (round += 1) {
            std.crypto.hash.Sha1.hash(&digest, &digest, .{});
        }

        const take = @min(digest.len, out.len - offset);
        @memcpy(out[offset..][0..take], digest[0..take]);
        offset += take;

        // I_j = (I_j + B + 1) mod 2^(64*8), big-endian.
        var block: [v]u8 = undefined;
        for (0..v) |index| block[index] = digest[index % digest.len];

        var block_start: usize = 0;
        while (block_start < input_len) : (block_start += v) {
            var carry: u16 = 1;
            var index: usize = v;
            while (index > 0) {
                index -= 1;
                const sum = @as(u16, input[block_start + index]) +
                    @as(u16, block[index]) + carry;
                input[block_start + index] = @truncate(sum);
                carry = sum >> 8;
            }
        }
    }
}

fn appendBmpString(
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    passphrase: []const u8,
) ParseError!void {
    const view = std.unicode.Utf8View.init(passphrase) catch return error.InvalidPassword;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint <= 0xffff) {
            try appendUtf16Be(list, allocator, @intCast(codepoint));
        } else {
            const value = codepoint - 0x10000;
            try appendUtf16Be(list, allocator, @intCast(0xd800 + (value >> 10)));
            try appendUtf16Be(list, allocator, @intCast(0xdc00 + (value & 0x3ff)));
        }
    }
    try list.appendSlice(allocator, &.{ 0, 0 });
}

fn appendUtf16Be(
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    unit: u16,
) ParseError!void {
    try list.append(allocator, @intCast(unit >> 8));
    try list.append(allocator, @intCast(unit & 0xff));
}

fn roundUp(length: usize, block: usize) usize {
    return if (length == 0) 0 else (length + block - 1) / block * block;
}

fn fillRepeated(destination: []u8, source: []const u8) void {
    if (destination.len == 0) return;
    for (destination, 0..) |*byte, index| byte.* = source[index % source.len];
}

fn des3CbcDecrypt(
    allocator: std.mem.Allocator,
    ciphertext: []const u8,
    key: []const u8,
    iv: [8]u8,
) ParseError![]u8 {
    if (key.len != 16 and key.len != 24) return error.InvalidPfx;
    if (ciphertext.len == 0 or ciphertext.len % 8 != 0) return error.InvalidPfx;

    const k1 = DesKey.init(key[0..8]);
    const k2 = DesKey.init(key[8..16]);
    // Two-key 3DES reuses K1 as K3.
    const k3 = if (key.len == 24) DesKey.init(key[16..24]) else k1;

    const plain = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(plain);

    var previous = iv;
    var offset: usize = 0;
    while (offset < ciphertext.len) : (offset += 8) {
        const block: [8]u8 = ciphertext[offset..][0..8].*;
        var value = std.mem.readInt(u64, &block, .big);
        // EDE decryption: D(K3), E(K2), D(K1).
        value = k3.decryptBlock(value);
        value = k2.encryptBlock(value);
        value = k1.decryptBlock(value);
        var decrypted: [8]u8 = undefined;
        std.mem.writeInt(u64, &decrypted, value, .big);
        for (0..8) |index| plain[offset + index] = decrypted[index] ^ previous[index];
        previous = block;
    }

    return stripPadding(allocator, plain, 8);
}

fn rc2CbcDecrypt(
    allocator: std.mem.Allocator,
    ciphertext: []const u8,
    key: []const u8,
    effective_bits: u16,
    iv: [8]u8,
) ParseError![]u8 {
    if (ciphertext.len == 0 or ciphertext.len % 8 != 0) return error.InvalidPfx;

    const rc2 = Rc2.init(key, effective_bits);
    const plain = try allocator.alloc(u8, ciphertext.len);
    errdefer allocator.free(plain);

    var previous = iv;
    var offset: usize = 0;
    while (offset < ciphertext.len) : (offset += 8) {
        const block: [8]u8 = ciphertext[offset..][0..8].*;
        const decrypted = rc2.decryptBlock(block);
        for (0..8) |index| plain[offset + index] = decrypted[index] ^ previous[index];
        previous = block;
    }

    return stripPadding(allocator, plain, 8);
}

/// DES, implemented here because Zig 0.17 std does not ship it. Only the
/// pieces PFX needs: a 64-bit block cipher used in CBC and inside 3DES.
const DesKey = struct {
    subkeys: [16]u64,

    fn init(key: []const u8) DesKey {
        std.debug.assert(key.len == 8);
        const key_bytes: [8]u8 = key[0..8].*;
        const permuted = desPermute(std.mem.readInt(u64, &key_bytes, .big), 64, &pc1_table);

        var c: u32 = @intCast(permuted >> 28);
        var d: u32 = @truncate(permuted & 0x0fff_ffff);

        var self: DesKey = undefined;
        for (des_shifts, 0..) |shift, round| {
            c = rotl28(c, shift);
            d = rotl28(d, shift);
            const cd = (@as(u64, c) << 28) | @as(u64, d);
            self.subkeys[round] = desPermute(cd, 56, &pc2_table);
        }
        return self;
    }

    fn encryptBlock(self: *const DesKey, block: u64) u64 {
        return self.crypt(block, false);
    }

    fn decryptBlock(self: *const DesKey, block: u64) u64 {
        return self.crypt(block, true);
    }

    fn crypt(self: *const DesKey, block: u64, reverse: bool) u64 {
        const permuted = desPermute(block, 64, &ip_table);
        var left: u32 = @intCast(permuted >> 32);
        var right: u32 = @truncate(permuted);

        for (0..16) |round| {
            const subkey = if (reverse) self.subkeys[15 - round] else self.subkeys[round];
            const next = left ^ desF(right, subkey);
            left = right;
            right = next;
        }

        const preoutput = (@as(u64, right) << 32) | @as(u64, left);
        return desPermute(preoutput, 64, &fp_table);
    }
};

fn desF(right: u32, subkey: u64) u32 {
    const expanded = desPermute(@as(u64, right), 32, &e_table) ^ subkey;
    var substituted: u32 = 0;
    inline for (0..8) |index| {
        const six: u8 = @intCast((expanded >> (42 - 6 * index)) & 0x3f);
        const row: usize = ((six >> 4) & 0x2) | (six & 0x1);
        const column: usize = (six >> 1) & 0x0f;
        substituted = (substituted << 4) | sboxes[index][row * 16 + column];
    }
    return @intCast(desPermute(@as(u64, substituted), 32, &p_table));
}

/// Applies a 1-based DES bit-selection table to the low `in_bits` of `input`.
fn desPermute(input: u64, comptime in_bits: comptime_int, comptime table: []const u8) u64 {
    var output: u64 = 0;
    inline for (table) |position| {
        output = (output << 1) | ((input >> (in_bits - position)) & 1);
    }
    return output;
}

fn rotl28(value: u32, shift: u5) u32 {
    return ((value << shift) | (value >> @intCast(28 - shift))) & 0x0fff_ffff;
}

/// RC2 (RFC 2268), key expansion and decryption only. PFX uses it in CBC.
const Rc2 = struct {
    keys: [64]u16,

    fn init(key: []const u8, effective_bits: u16) Rc2 {
        std.debug.assert(key.len >= 1 and key.len <= 128);
        var expanded: [128]u8 = @splat(0);
        @memcpy(expanded[0..key.len], key);

        var index = key.len;
        while (index < expanded.len) : (index += 1) {
            const sum: u8 = expanded[index - 1] +% expanded[index - key.len];
            expanded[index] = pitable[sum];
        }

        const t8: usize = (effective_bits + 7) / 8;
        const mask: u8 = @truncate((@as(u16, 1) << @intCast(8 + effective_bits - 8 * t8)) - 1);
        expanded[128 - t8] = pitable[expanded[128 - t8] & mask];

        index = 128 - t8;
        while (index > 0) {
            index -= 1;
            expanded[index] = pitable[expanded[index + 1] ^ expanded[index + t8]];
        }

        var self: Rc2 = undefined;
        for (0..64) |word| {
            self.keys[word] = @as(u16, expanded[2 * word]) |
                (@as(u16, expanded[2 * word + 1]) << 8);
        }
        return self;
    }

    fn decryptBlock(self: *const Rc2, block: [8]u8) [8]u8 {
        var words: [4]u16 = undefined;
        for (0..4) |word| {
            const pair: [2]u8 = block[2 * word ..][0..2].*;
            words[word] = std.mem.readInt(u16, &pair, .little);
        }

        var j: i32 = 63;
        var round: usize = 0;
        while (round < 5) : (round += 1) rc2RMix(&words, &self.keys, &j);
        rc2RMash(&words, &self.keys);
        round = 0;
        while (round < 6) : (round += 1) rc2RMix(&words, &self.keys, &j);
        rc2RMash(&words, &self.keys);
        round = 0;
        while (round < 5) : (round += 1) rc2RMix(&words, &self.keys, &j);

        var output: [8]u8 = undefined;
        for (0..4) |word| {
            std.mem.writeInt(u16, output[2 * word ..][0..2], words[word], .little);
        }
        return output;
    }
};

fn rc2RMix(words: *[4]u16, keys: *const [64]u16, j: *i32) void {
    const shifts = [4]u4{ 1, 2, 3, 5 };
    inline for (0..4) |step| {
        const i = 3 - step;
        words[i] = std.math.rotr(u16, words[i], shifts[i]);
        const prev1 = words[(i + 3) % 4];
        const prev2 = words[(i + 2) % 4];
        const prev3 = words[(i + 1) % 4];
        words[i] -%= keys[@intCast(j.*)] +% (prev1 & prev2) +% ((~prev1) & prev3);
        j.* -= 1;
    }
}

fn rc2RMash(words: *[4]u16, keys: *const [64]u16) void {
    inline for (0..4) |step| {
        const i = 3 - step;
        words[i] -%= keys[@intCast(words[(i + 3) % 4] & 63)];
    }
}

/// Minimal AES block cipher. Std only exposes AES-128/256, and PFX files may
/// use AES-192, so all three key sizes are implemented here. Only the inverse
/// cipher is used: PFX decryption is CBC.
const Aes = struct {
    round_keys: [240]u8 = undefined,
    rounds: usize,

    fn init(key: []const u8) Aes {
        std.debug.assert(key.len == 16 or key.len == 24 or key.len == 32);
        var self: Aes = .{ .rounds = key.len / 4 + 6 };

        const words = key.len / 4;
        const total_words = 4 * (self.rounds + 1);
        @memcpy(self.round_keys[0..key.len], key);

        var word = words;
        var rcon: u8 = 1;
        while (word < total_words) : (word += 1) {
            var temp = [4]u8{
                self.round_keys[(word - 1) * 4 + 0],
                self.round_keys[(word - 1) * 4 + 1],
                self.round_keys[(word - 1) * 4 + 2],
                self.round_keys[(word - 1) * 4 + 3],
            };

            if (word % words == 0) {
                const first = temp[0];
                temp[0] = sbox[temp[1]] ^ rcon;
                temp[1] = sbox[temp[2]];
                temp[2] = sbox[temp[3]];
                temp[3] = sbox[first];
                rcon = xtime(rcon);
            } else if (words > 6 and word % words == 4) {
                for (&temp) |*byte| byte.* = sbox[byte.*];
            }

            for (0..4) |index| {
                self.round_keys[word * 4 + index] =
                    self.round_keys[(word - words) * 4 + index] ^ temp[index];
            }
        }

        return self;
    }

    fn decryptBlock(self: *const Aes, input: *const [16]u8) [16]u8 {
        var state: [16]u8 = input.*;
        addRoundKey(&state, self.roundKey(self.rounds));

        var round = self.rounds;
        while (round > 1) : (round -= 1) {
            invShiftRows(&state);
            invSubBytes(&state);
            addRoundKey(&state, self.roundKey(round - 1));
            invMixColumns(&state);
        }

        invShiftRows(&state);
        invSubBytes(&state);
        addRoundKey(&state, self.roundKey(0));
        return state;
    }

    fn roundKey(self: *const Aes, round: usize) *const [16]u8 {
        return self.round_keys[round * 16 ..][0..16];
    }
};

fn addRoundKey(state: *[16]u8, key: *const [16]u8) void {
    for (state, key) |*byte, key_byte| byte.* ^= key_byte;
}

fn invShiftRows(state: *[16]u8) void {
    var shifted: [16]u8 = undefined;
    for (0..4) |row| {
        for (0..4) |column| {
            shifted[row + 4 * column] = state[row + 4 * ((column + 4 - row) % 4)];
        }
    }
    state.* = shifted;
}

fn invSubBytes(state: *[16]u8) void {
    for (state) |*byte| byte.* = inv_sbox[byte.*];
}

fn invMixColumns(state: *[16]u8) void {
    for (0..4) |column| {
        const a0 = state[4 * column + 0];
        const a1 = state[4 * column + 1];
        const a2 = state[4 * column + 2];
        const a3 = state[4 * column + 3];

        state[4 * column + 0] = gfMul(a0, 14) ^ gfMul(a1, 11) ^ gfMul(a2, 13) ^ gfMul(a3, 9);
        state[4 * column + 1] = gfMul(a0, 9) ^ gfMul(a1, 14) ^ gfMul(a2, 11) ^ gfMul(a3, 13);
        state[4 * column + 2] = gfMul(a0, 13) ^ gfMul(a1, 9) ^ gfMul(a2, 14) ^ gfMul(a3, 11);
        state[4 * column + 3] = gfMul(a0, 11) ^ gfMul(a1, 13) ^ gfMul(a2, 9) ^ gfMul(a3, 14);
    }
}

fn xtime(value: u8) u8 {
    return (value << 1) ^ (if (value & 0x80 != 0) @as(u8, 0x1b) else 0);
}

fn gfMul(a: u8, b: u8) u8 {
    var result: u8 = 0;
    var left = a;
    var right = b;
    while (right != 0) : (right >>= 1) {
        if (right & 1 != 0) result ^= left;
        left = xtime(left);
    }
    return result;
}

const sbox: [256]u8 = blk: {
    @setEvalBranchQuota(20_000);
    var box: [256]u8 = undefined;
    var p: u8 = 1;
    var q: u8 = 1;
    for (0..256) |_| {
        p = gfMul(p, 3);
        q = gfMul(q, 0xf6);
        var value: u8 = q ^ 0x63;
        value ^= std.math.rotl(u8, q, 1);
        value ^= std.math.rotl(u8, q, 2);
        value ^= std.math.rotl(u8, q, 3);
        value ^= std.math.rotl(u8, q, 4);
        box[p] = value;
    }
    box[0x00] = 0x63;
    break :blk box;
};

const inv_sbox: [256]u8 = blk: {
    var box: [256]u8 = undefined;
    for (sbox, 0..) |value, index| box[value] = @intCast(index);
    break :blk box;
};

fn appendPem(
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    label: []const u8,
    der: []const u8,
) ParseError!void {
    try list.appendSlice(allocator, "-----BEGIN ");
    try list.appendSlice(allocator, label);
    try list.appendSlice(allocator, "-----\n");

    const encoded_length = std.base64.standard.Encoder.calcSize(der.len);
    const encoded_buffer = try allocator.alloc(u8, encoded_length);
    defer allocator.free(encoded_buffer);
    const encoded = std.base64.standard.Encoder.encode(encoded_buffer, der);

    var offset: usize = 0;
    while (offset < encoded.len) {
        const end = @min(offset + 64, encoded.len);
        try list.appendSlice(allocator, encoded[offset..end]);
        try list.append(allocator, '\n');
        offset = end;
    }

    try list.appendSlice(allocator, "-----END ");
    try list.appendSlice(allocator, label);
    try list.appendSlice(allocator, "-----\n");
}

const tag_integer: u8 = 0x02;
const tag_octet_string: u8 = 0x04;
const tag_oid: u8 = 0x06;
const tag_sequence: u8 = 0x30;
const tag_explicit_0: u8 = 0xa0;
const tag_implicit_0: u8 = 0x80;

const oid_data = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01 };
const oid_encrypted_data = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x06 };
const oid_cert_bag = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x0a, 0x01, 0x03 };
const oid_key_bag = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x0a, 0x01, 0x01 };
const oid_shrouded_key_bag = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x0a, 0x01, 0x02 };
const oid_x509_certificate = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x16, 0x01 };
const oid_pbes2 = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0d };
const oid_pbkdf2 = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0c };
const oid_hmac_sha1 = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x07 };
const oid_hmac_sha224 = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x08 };
const oid_hmac_sha256 = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x09 };
const oid_hmac_sha384 = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x0a };
const oid_hmac_sha512 = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x0b };
const oid_aes128_cbc = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x02 };
const oid_aes192_cbc = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x16 };
const oid_aes256_cbc = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2a };
const oid_pbe_sha1_3des = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x01, 0x03 };
const oid_pbe_sha1_2des = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x01, 0x04 };
const oid_pbe_sha1_rc2_128 = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x01, 0x05 };
const oid_pbe_sha1_rc2_40 = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x01, 0x06 };

const ip_table = [_]u8{
    58, 50, 42, 34, 26, 18, 10, 2,
    60, 52, 44, 36, 28, 20, 12, 4,
    62, 54, 46, 38, 30, 22, 14, 6,
    64, 56, 48, 40, 32, 24, 16, 8,
    57, 49, 41, 33, 25, 17, 9,  1,
    59, 51, 43, 35, 27, 19, 11, 3,
    61, 53, 45, 37, 29, 21, 13, 5,
    63, 55, 47, 39, 31, 23, 15, 7,
};

const fp_table = [_]u8{
    40, 8, 48, 16, 56, 24, 64, 32,
    39, 7, 47, 15, 55, 23, 63, 31,
    38, 6, 46, 14, 54, 22, 62, 30,
    37, 5, 45, 13, 53, 21, 61, 29,
    36, 4, 44, 12, 52, 20, 60, 28,
    35, 3, 43, 11, 51, 19, 59, 27,
    34, 2, 42, 10, 50, 18, 58, 26,
    33, 1, 41, 9,  49, 17, 57, 25,
};

const e_table = [_]u8{
    32, 1,  2,  3,  4,  5,
    4,  5,  6,  7,  8,  9,
    8,  9,  10, 11, 12, 13,
    12, 13, 14, 15, 16, 17,
    16, 17, 18, 19, 20, 21,
    20, 21, 22, 23, 24, 25,
    24, 25, 26, 27, 28, 29,
    28, 29, 30, 31, 32, 1,
};

const p_table = [_]u8{
    16, 7,  20, 21, 29, 12, 28, 17,
    1,  15, 23, 26, 5,  18, 31, 10,
    2,  8,  24, 14, 32, 27, 3,  9,
    19, 13, 30, 6,  22, 11, 4,  25,
};

const pc1_table = [_]u8{
    57, 49, 41, 33, 25, 17, 9,
    1,  58, 50, 42, 34, 26, 18,
    10, 2,  59, 51, 43, 35, 27,
    19, 11, 3,  60, 52, 44, 36,
    63, 55, 47, 39, 31, 23, 15,
    7,  62, 54, 46, 38, 30, 22,
    14, 6,  61, 53, 45, 37, 29,
    21, 13, 5,  28, 20, 12, 4,
};

const pc2_table = [_]u8{
    14, 17, 11, 24, 1,  5,
    3,  28, 15, 6,  21, 10,
    23, 19, 12, 4,  26, 8,
    16, 7,  27, 20, 13, 2,
    41, 52, 31, 37, 47, 55,
    30, 40, 51, 45, 33, 48,
    44, 49, 39, 56, 34, 53,
    46, 42, 50, 36, 29, 32,
};

const des_shifts = [_]u5{ 1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1 };

const sboxes = [8][64]u8{
    .{
        14, 4,  13, 1, 2,  15, 11, 8,  3,  10, 6,  12, 5,  9,  0, 7,
        0,  15, 7,  4, 14, 2,  13, 1,  10, 6,  12, 11, 9,  5,  3, 8,
        4,  1,  14, 8, 13, 6,  2,  11, 15, 12, 9,  7,  3,  10, 5, 0,
        15, 12, 8,  2, 4,  9,  1,  7,  5,  11, 3,  14, 10, 0,  6, 13,
    },
    .{
        15, 1,  8,  14, 6,  11, 3,  4,  9,  7, 2,  13, 12, 0, 5,  10,
        3,  13, 4,  7,  15, 2,  8,  14, 12, 0, 1,  10, 6,  9, 11, 5,
        0,  14, 7,  11, 10, 4,  13, 1,  5,  8, 12, 6,  9,  3, 2,  15,
        13, 8,  10, 1,  3,  15, 4,  2,  11, 6, 7,  12, 0,  5, 14, 9,
    },
    .{
        10, 0,  9,  14, 6, 3,  15, 5,  1,  13, 12, 7,  11, 4,  2,  8,
        13, 7,  0,  9,  3, 4,  6,  10, 2,  8,  5,  14, 12, 11, 15, 1,
        13, 6,  4,  9,  8, 15, 3,  0,  11, 1,  2,  12, 5,  10, 14, 7,
        1,  10, 13, 0,  6, 9,  8,  7,  4,  15, 14, 3,  11, 5,  2,  12,
    },
    .{
        7,  13, 14, 3, 0,  6,  9,  10, 1,  2, 8, 5,  11, 12, 4,  15,
        13, 8,  11, 5, 6,  15, 0,  3,  4,  7, 2, 12, 1,  10, 14, 9,
        10, 6,  9,  0, 12, 11, 7,  13, 15, 1, 3, 14, 5,  2,  8,  4,
        3,  15, 0,  6, 10, 1,  13, 8,  9,  4, 5, 11, 12, 7,  2,  14,
    },
    .{
        2,  12, 4,  1,  7,  10, 11, 6,  8,  5,  3,  15, 13, 0, 14, 9,
        14, 11, 2,  12, 4,  7,  13, 1,  5,  0,  15, 10, 3,  9, 8,  6,
        4,  2,  1,  11, 10, 13, 7,  8,  15, 9,  12, 5,  6,  3, 0,  14,
        11, 8,  12, 7,  1,  14, 2,  13, 6,  15, 0,  9,  10, 4, 5,  3,
    },
    .{
        12, 1,  10, 15, 9, 2,  6,  8,  0,  13, 3,  4,  14, 7,  5,  11,
        10, 15, 4,  2,  7, 12, 9,  5,  6,  1,  13, 14, 0,  11, 3,  8,
        9,  14, 15, 5,  2, 8,  12, 3,  7,  0,  4,  10, 1,  13, 11, 6,
        4,  3,  2,  12, 9, 5,  15, 10, 11, 14, 1,  7,  6,  0,  8,  13,
    },
    .{
        4,  11, 2,  14, 15, 0, 8,  13, 3,  12, 9, 7,  5,  10, 6, 1,
        13, 0,  11, 7,  4,  9, 1,  10, 14, 3,  5, 12, 2,  15, 8, 6,
        1,  4,  11, 13, 12, 3, 7,  14, 10, 15, 6, 8,  0,  5,  9, 2,
        6,  11, 13, 8,  1,  4, 10, 7,  9,  5,  0, 15, 14, 2,  3, 12,
    },
    .{
        13, 2,  8,  4, 6,  15, 11, 1,  10, 9,  3,  14, 5,  0,  12, 7,
        1,  15, 13, 8, 10, 3,  7,  4,  12, 5,  6,  11, 0,  14, 9,  2,
        7,  11, 4,  1, 9,  12, 14, 2,  0,  6,  10, 13, 15, 3,  5,  8,
        2,  1,  14, 7, 4,  10, 8,  13, 15, 12, 9,  0,  3,  5,  6,  11,
    },
};

const pitable = [256]u8{
    0xd9, 0x78, 0xf9, 0xc4, 0x19, 0xdd, 0xb5, 0xed, 0x28, 0xe9, 0xfd, 0x79, 0x4a, 0xa0, 0xd8, 0x9d,
    0xc6, 0x7e, 0x37, 0x83, 0x2b, 0x76, 0x53, 0x8e, 0x62, 0x4c, 0x64, 0x88, 0x44, 0x8b, 0xfb, 0xa2,
    0x17, 0x9a, 0x59, 0xf5, 0x87, 0xb3, 0x4f, 0x13, 0x61, 0x45, 0x6d, 0x8d, 0x09, 0x81, 0x7d, 0x32,
    0xbd, 0x8f, 0x40, 0xeb, 0x86, 0xb7, 0x7b, 0x0b, 0xf0, 0x95, 0x21, 0x22, 0x5c, 0x6b, 0x4e, 0x82,
    0x54, 0xd6, 0x65, 0x93, 0xce, 0x60, 0xb2, 0x1c, 0x73, 0x56, 0xc0, 0x14, 0xa7, 0x8c, 0xf1, 0xdc,
    0x12, 0x75, 0xca, 0x1f, 0x3b, 0xbe, 0xe4, 0xd1, 0x42, 0x3d, 0xd4, 0x30, 0xa3, 0x3c, 0xb6, 0x26,
    0x6f, 0xbf, 0x0e, 0xda, 0x46, 0x69, 0x07, 0x57, 0x27, 0xf2, 0x1d, 0x9b, 0xbc, 0x94, 0x43, 0x03,
    0xf8, 0x11, 0xc7, 0xf6, 0x90, 0xef, 0x3e, 0xe7, 0x06, 0xc3, 0xd5, 0x2f, 0xc8, 0x66, 0x1e, 0xd7,
    0x08, 0xe8, 0xea, 0xde, 0x80, 0x52, 0xee, 0xf7, 0x84, 0xaa, 0x72, 0xac, 0x35, 0x4d, 0x6a, 0x2a,
    0x96, 0x1a, 0xd2, 0x71, 0x5a, 0x15, 0x49, 0x74, 0x4b, 0x9f, 0xd0, 0x5e, 0x04, 0x18, 0xa4, 0xec,
    0xc2, 0xe0, 0x41, 0x6e, 0x0f, 0x51, 0xcb, 0xcc, 0x24, 0x91, 0xaf, 0x50, 0xa1, 0xf4, 0x70, 0x39,
    0x99, 0x7c, 0x3a, 0x85, 0x23, 0xb8, 0xb4, 0x7a, 0xfc, 0x02, 0x36, 0x5b, 0x25, 0x55, 0x97, 0x31,
    0x2d, 0x5d, 0xfa, 0x98, 0xe3, 0x8a, 0x92, 0xae, 0x05, 0xdf, 0x29, 0x10, 0x67, 0x6c, 0xba, 0xc9,
    0xd3, 0x00, 0xe6, 0xcf, 0xe1, 0x9e, 0xa8, 0x2c, 0x63, 0x16, 0x01, 0x3f, 0x58, 0xe2, 0x89, 0xa9,
    0x0d, 0x38, 0x34, 0x1b, 0xab, 0x33, 0xff, 0xb0, 0xbb, 0x48, 0x0c, 0x5f, 0xb9, 0xb1, 0xcd, 0x2e,
    0xc5, 0xf3, 0xdb, 0x47, 0xe5, 0xa5, 0x9c, 0x77, 0x0a, 0xa6, 0x20, 0x68, 0xfe, 0x7f, 0xc1, 0xad,
};

test "DES known-answer vector" {
    const key = [_]u8{ 0x13, 0x34, 0x57, 0x79, 0x9b, 0xbc, 0xdf, 0xf1 };
    const des = DesKey.init(&key);

    try std.testing.expectEqual(
        @as(u64, 0x85e813540f0ab405),
        des.encryptBlock(0x0123456789abcdef),
    );
    try std.testing.expectEqual(
        @as(u64, 0x0123456789abcdef),
        des.decryptBlock(0x85e813540f0ab405),
    );
}

test "3DES known-answer vector" {
    const key = [_]u8{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
        0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01,
        0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23,
    };
    const k1 = DesKey.init(key[0..8]);
    const k2 = DesKey.init(key[8..16]);
    const k3 = DesKey.init(key[16..24]);

    var value: u64 = 0xf2afd84ee809e2b5;
    value = k3.decryptBlock(value);
    value = k2.encryptBlock(value);
    value = k1.decryptBlock(value);
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), value);
}

test "RC2 known-answer vectors" {
    // RFC 2268 vector, effective key length 128 bits.
    const key128 = [_]u8{ 0x88, 0xbc, 0xa9, 0x0e, 0x90, 0x87, 0x5a, 0x7f, 0x0f, 0x79, 0xc3, 0x84, 0x62, 0x7b, 0xaf, 0xb2 };
    const rc2_128 = Rc2.init(&key128, 128);
    const decrypted_128 = rc2_128.decryptBlock(.{ 0x22, 0x69, 0x55, 0x2a, 0xb0, 0xf8, 0x5c, 0xa6 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, &decrypted_128);

    // 40-bit effective key, as used by pbeWithSHA1And40BitRC2-CBC.
    const key40 = [_]u8{ 0, 0, 0, 0, 0 };
    const rc2_40 = Rc2.init(&key40, 40);
    const decrypted_40 = rc2_40.decryptBlock(.{ 0xc0, 0xb8, 0xff, 0xa5, 0xd6, 0xeb, 0xc9, 0x62 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 }, &decrypted_40);
}

test "PKCS#12 password is a NUL-terminated BMPString" {
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(std.testing.allocator);

    try appendBmpString(&encoded, std.testing.allocator, "Beavis");
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x00, 0x42, 0x00, 0x65, 0x00, 0x61, 0x00, 0x76,
            0x00, 0x69, 0x00, 0x73, 0x00, 0x00,
        },
        encoded.items,
    );
}
