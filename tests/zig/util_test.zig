const std = @import("std");
const helpers = @import("helpers.zig");

fn expectFixture(allocator: std.mem.Allocator, name: []const u8, expected: []const u8) !void {
    const actual = try helpers.runFixture(allocator, name);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "util format, inspect, types, and callback bridges" {
    try expectFixture(std.testing.allocator, "util.js",
        \\format-specifiers=str 42.7 42 2.5 {"a":1}
        \\format-percent=x %
        \\format-extra=hello world 1 { a: 1 } [ 'x' ]
        \\format-object={ a: 1 }
        \\format-string-object={ a: [Array] }
        \\format-missing=1 %d
        \\format-control=xy
        \\format-json-circular=[Circular]
        \\format-bigint=5n 5
        \\format-numbers=3.9:3
        \\format-s-custom=custom
        \\inspect-nested={ a: { b: { c: 1 } } }
        \\inspect-depth={ a: { b: [Object] } }
        \\inspect-depth-zero={ a: [Object] }
        \\inspect-cycle={ name: 'cycle', self: [Circular] }
        \\inspect-map=Map(1) { 'a' => 1 }
        \\inspect-set=Set(2) { 1, 2 }
        \\inspect-buffer=<Buffer 68 69>
        \\inspect-function=[Function: named]
        \\inspect-class=Widget { id: 1 }
        \\inspect-date=1970-01-01T00:00:00.000Z
        \\inspect-regexp=/ab/gi
        \\inspect-error=Error: boom
        \\inspect-typed=Uint8Array(2) [ 1, 2 ]
        \\inspect-hidden={ visible: 1 }:{ visible: 1, [secret]: 2 }
        \\inspect-sorted={ a: 2, b: 1 }
        \\inspect-max-array=[ 1, 2, ... 1 more item ]
        \\inspect-holes=[ 1, <1 empty item>, 3 ]
        \\inspect-multiline="{\n  a: 1\n}"
        \\inspect-colors=1
        \\inspect-bigint=1n
        \\inspect-string='a\nb'
        \\inspect-null=null:undefined
        \\types=true,true,true,true,false,true,true,true,true,true,false,true
        \\promisify=5
        \\promisify-error=nope
        \\promisify-multiple=a+b
        \\promisify-custom=custom:symbol
        \\callbackify-value=2
        \\callbackify-error=bad
        \\inherits=true:true:base
        \\deprecate=result:1
        \\deep-nan=true
        \\deep-negative-zero=false
        \\deep-object=true
        \\deep-mismatch=false
        \\deep-cycle=true
        \\deep-date=true:false
        \\deep-regexp=true:false
        \\deep-map=true
        \\deep-set=true
        \\deep-typed=true:false
        \\deep-buffer=false
        \\deep-error=true:false
        \\encoding=226,130,172:€
        \\default-export=function:function:true:true
        \\default-surface=function:function:function:function:function:function
        \\
    );
}

test "util modules keep TextEncoder and TextDecoder exports" {
    const allocator = std.testing.allocator;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    const runtime = try helpers.initRuntime(&writer.writer);
    defer runtime.deinit();

    const value = try runtime.eval(
        \\globalThis.__result = (() => {
        \\  const { TextEncoder, TextDecoder } = globalThis;
        \\  const encoded = new TextEncoder().encode('\u{20ac}');
        \\  const decoded = new TextDecoder().decode(encoded);
        \\  return `${encoded.length}:${decoded}`;
        \\})();
    , "<test>");
    value.deinit(runtime.context());
    try runtime.run();

    const result = try helpers.readResult(allocator, runtime);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("3:€", result);
}
