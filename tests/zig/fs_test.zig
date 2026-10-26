const std = @import("std");
const helpers = @import("helpers.zig");

test "async fs fixture" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "fs.js");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\write=hello
        \\append=hello world
        \\stat=true:11:true
        \\readdir=a.txt,sub
        \\dirent=a.txt:false,sub:true:true
        \\copy=hello world
        \\realpath=true
        \\symlink=a.txt:true:true
        \\cp=hello world
        \\truncate=hello
        \\unlink=true
        \\eexist=EEXIST:mkdir:true
        \\callback-before-return=false
        \\callback=hello world
        \\parity=true
        \\callback-error=ENOENT
        \\bytes=true:11
        \\enoent=ENOENT:open:true:true
        \\sync=ERR_METHOD_NOT_IMPLEMENTED
        \\existsSync=undefined
        \\promises-same=true
        \\alias=true
        \\cleanup=true
        \\
    , actual);
}
