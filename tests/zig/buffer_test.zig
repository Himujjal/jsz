const std = @import("std");
const helpers = @import("helpers.zig");

fn expectFixture(name: []const u8, expected: []const u8) !void {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, name);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "Buffer.from copies arrays and shares ArrayBuffers" {
    try expectFixture("buffer/from.mjs",
        \\string=abc
        \\instance=true:true
        \\array=0102ff:3
        \\copy=true:9
        \\shared=true:4
        \\window=2:1
        \\hex=hi
        \\default=2
        \\empty=0
        \\proto=true
        \\
    );
}

test "Buffer encodes and decodes every supported encoding" {
    try expectFixture("buffer/encodings.mjs",
        \\hex=68656c6c6f20776f726c64
        \\base64=aGVsbG8gd29ybGQ=
        \\base64url=aGVsbG8gd29ybGQ
        \\utf8=hello world
        \\upper=hello world
        \\hex-in=hello
        \\base64-in=hello world
        \\base64-nopad=hello world
        \\base64url-in=hello world
        \\hex-short=1
        \\hex-bad=0
        \\latin1=true
        \\binary=true
        \\latin1-encode=e9
        \\ascii-encode=e9
        \\ascii-decode=i
        \\latin1-hi=true
        \\utf16le-encode=610062006300
        \\utf16le-decode=true
        \\utf16le-euro=ac20
        \\utf16le-odd=a
        \\replacement=true
        \\multibyte=true
        \\length-utf8=2
        \\length-latin1=1
        \\length-ascii=1
        \\length-utf16le=6
        \\length-hex=2
        \\length-base64=3
        \\length-buffer=11
        \\slice=bcd
        \\slice-empty=true
        \\
    );
}

test "Buffer alloc, allocUnsafe, concat, and fill" {
    try expectFixture("buffer/alloc_concat.mjs",
        \\alloc=00000000
        \\alloc-fill=abab
        \\alloc-byte=AAAA
        \\alloc-empty=0
        \\unsafe-length=3
        \\concat=abcd
        \\concat-total=abc:3
        \\concat-longer=616263640000
        \\concat-empty=0
        \\fill-return=true:......
        \\fill-range=00010100
        \\
    );
}

test "Buffer slice aliases, compare, search, copy, and write" {
    try expectFixture("buffer/methods.mjs",
        \\slice=cd:true
        \\slice-alias=abZdef
        \\equals=true:false
        \\compare=-1:1:0
        \\compare-length=1
        \\index=1:4
        \\last-index=4
        \\includes=true:false
        \\index-byte=2
        \\copy=3:0078797a
        \\write=4:abcd.
        \\write-limited=2:zzcd.
        \\json={"type":"Buffer","data":[1,2]}
        \\keys=0
        \\
    );
}

test "fixed-width accessors round-trip and reject out-of-range offsets" {
    try expectFixture("buffer/readwrite.mjs",
        \\write-returns=1:A
        \\u32be=1020304
        \\u32le=1020304
        \\i16le=-2
        \\u16be=65535
        \\u64=102030405060708
        \\float=1.5
        \\double=2.25
        \\range=RangeError:ERR_OUT_OF_RANGE
        \\write-range=RangeError:ERR_OUT_OF_RANGE
        \\
    );
}

test "Buffer helpers, constants, and encoding names" {
    try expectFixture("buffer/isbuffer.mjs",
        \\is-buffer=true:false:false
        \\is-encoding=true:true:false
        \\pool=number:true
        \\inspect-max=50
        \\kmax=true:true
        \\constants=true:true
        \\filled=true:true
        \\
    );
}

test "TextEncoder and TextDecoder cover utf8, utf16le, and latin1" {
    try expectFixture("buffer/text_encoding.mjs",
        \\encoder-label=utf-8
        \\decoder-label=utf-8:false:false
        \\encode=e2,82,ac
        \\encode-default=0
        \\decode=true
        \\decode-empty=true
        \\decode-arraybuffer=hi
        \\utf16le=true
        \\latin1=true
        \\encode-into=0:0:0,0
        \\encode-into-small={"read":0,"written":0}:0
        \\bom=A
        \\bom-ignore=2
        \\fatal=TypeError:ERR_ENCODING_INVALID_ENCODED_DATA
        \\label=RangeError:ERR_ENCODING_NOT_SUPPORTED
        \\imports=function:function
        \\
    );
}

test "atob and btoa round-trip and reject invalid input" {
    try expectFixture("buffer/atob_btoa.mjs",
        \\btoa=aGVsbG8=
        \\atob=hello
        \\roundtrip=hello world
        \\empty=true
        \\binary=true
        \\whitespace=hello
        \\invalid=InvalidCharacterError
        \\global=true:true
        \\bytes=aGVsbG8=
        \\
    );
}

test "Buffer is a global and fs returns Buffers without an encoding" {
    try expectFixture("buffer/globals.mjs",
        \\global=true
        \\default=true
        \\buffer=abc
        \\fs-buffer=true:true:hello
        \\fs-text=string:hello
        \\fs-hex=68656c6c6f
        \\
    );
}

test "unknown encodings report ERR_UNKNOWN_ENCODING" {
    const allocator = std.testing.allocator;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    const runtime = try helpers.initRuntime(&writer.writer);
    defer runtime.deinit();

    const value = try runtime.eval(
        \\globalThis.__result = (() => {
        \\  try {
        \\    Buffer.from('x', 'lol');
        \\    return 'no-throw';
        \\  } catch (error) {
        \\    return error.name + ':' + error.code;
        \\  }
        \\})();
    , "<test>");
    value.deinit(runtime.context());
    try runtime.run();

    const result = try helpers.readResult(allocator, runtime);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("TypeError:ERR_UNKNOWN_ENCODING", result);
}
