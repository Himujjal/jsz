const std = @import("std");
const helpers = @import("helpers.zig");

fn expectFixture(allocator: std.mem.Allocator, name: []const u8, expected: []const u8) !void {
    const actual = try helpers.runFixture(allocator, name);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "EventEmitter listener, once, error, and meta semantics" {
    try expectFixture(std.testing.allocator, "events.js",
        \\emit-order=true:b:true,a
        \\emit-none=false
        \\once-raw=function:true:true
        \\once-listeners=true
        \\once-fired=1:0
        \\remove-once=0:0
        \\prepend=prepend-once,prepend,on,prepend,on
        \\error-throw=Error:boom
        \\error-wrap=ERR_UNHANDLED_ERROR:string-error
        \\meta=new:removeListener,new:foo,remove:foo
        \\event-names=newListener,removeListener
        \\during-emit=first:2
        \\max-default=10:10
        \\max-set=true:3
        \\remove-all-one=b
        \\remove-all=0
        \\default-export=true:true:function
        \\once-resolve=1,2
        \\once-cleanup=0:0
        \\once-reject=Error:failed
        \\once-reject-cleanup=0:0
        \\once-error=direct
        \\
    );
}

test "EventEmitter validates listeners and wraps non-error emissions" {
    const allocator = std.testing.allocator;
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    const runtime = try helpers.initRuntime(&writer.writer);
    defer runtime.deinit();

    const value = try runtime.eval(
        \\globalThis.__result = 'pending';
        \\import('node:events').then(({ EventEmitter }) => {
        \\  const parts = [];
        \\  try {
        \\    new EventEmitter().on('x', 1);
        \\    parts.push('no-throw');
        \\  } catch (error) {
        \\    parts.push(`${error.name}:${error.code}`);
        \\  }
        \\  try {
        \\    new EventEmitter().emit('error', 'value');
        \\  } catch (error) {
        \\    parts.push(`${error.code}:${error.context}`);
        \\  }
        \\  globalThis.__result = parts.join('|');
        \\});
    , "<test>");
    value.deinit(runtime.context());
    try runtime.run();

    const result = try helpers.readResult(allocator, runtime);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("TypeError:ERR_INVALID_ARG_TYPE|ERR_UNHANDLED_ERROR:value", result);
}
