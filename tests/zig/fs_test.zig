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

test "descriptor fs fixture" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "fs_fd.js");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\mkdtemp=true:true:true:true:true
        \\mkdtemp-cleaned=true
        \\mkdtemp-callback=true
        \\mkdtemp-empty=ERR_INVALID_ARG_VALUE
        \\mkdtemp-sep=ERR_INVALID_ARG_VALUE
        \\open=number:true
        \\fstat=11:true
        \\read=3:wor:true
        \\write-string=2:XY
        \\closed=EBADF:read
        \\closed-fstat=EBADF:fstat
        \\closed-fsync=EBADF:fsync
        \\wx=true
        \\wx-twice=EEXIST:open:true
        \\open-enoent=ENOENT:open
        \\open-bad-flag=ERR_INVALID_ARG_VALUE
        \\open-bad-flag-async=ERR_INVALID_ARG_VALUE
        \\filehandle=number:6:abcdef:2:bc
        \\filehandle-edit=abZ
        \\filehandle-close-twice=true
        \\filehandle-closed=EBADF
        \\filehandle-closed-truncate=EBADF
        \\filehandle-closed-stat=EBADF
        \\append=abZ+w+a
        \\big=true:1048576
        \\promise-fd-api=undefined,undefined,undefined,undefined,undefined
        \\cleanup=true
        \\
    , actual);
}

test "fs hardening fixture" {
    const actual = try helpers.runFixtureStdout(std.testing.allocator, "fs/hardening.js");
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualStrings(
        \\recursive=a.txt,sub,sub/b.txt,sub/deep,sub/deep/c.txt
        \\recursive-root=false
        \\typed=a.txt@tests/fixtures/.fs-hardening-work,sub@tests/fixtures/.fs-hardening-work,b.txt@tests/fixtures/.fs-hardening-work/sub,deep@tests/fixtures/.fs-hardening-work/sub,c.txt@tests/fixtures/.fs-hardening-work/sub/deep
        \\typed-basename=true
        \\typed-path-alias=true:false
        \\callback-recursive=true
        \\flat-parent=true:true
        \\numeric-write=onetwo
        \\numeric-truncate=reset
        \\numeric-exclusive=EEXIST:reset
        \\numeric-open=num
        \\numeric-callback=resetcb
        \\numeric-invalid=ERR_INVALID_ARG_VALUE,ERR_INVALID_ARG_VALUE,ERR_INVALID_ARG_VALUE,ERR_INVALID_ARG_VALUE,ERR_INVALID_ARG_VALUE
        \\numeric-invalid-write=ERR_INVALID_ARG_VALUE:resetcb
        \\numeric-invalid-sync=ERR_INVALID_ARG_VALUE
        \\append-seq=base123
        \\append-numeric=base12345
        \\rename-dest=ENOENT|rename|tests/fixtures/.fs-hardening-work/absent.txt|tests/fixtures/.fs-hardening-work/moved.txt
        \\copy-dest=ENOENT|copyfile|tests/fixtures/.fs-hardening-work/absent.txt|tests/fixtures/.fs-hardening-work/copy.txt
        \\link-dest=ENOENT|link|tests/fixtures/.fs-hardening-work/absent.txt|tests/fixtures/.fs-hardening-work/hard.txt
        \\cp-dest=ERR_FS_EISDIR|cp|tests/fixtures/.fs-hardening-work/sub|tests/fixtures/.fs-hardening-work/subcopy
        \\symlink-dest=EEXIST|symlink|a.txt|tests/fixtures/.fs-hardening-work/sym.txt
        \\stat-block=true:true:true
        \\cleanup=true
        \\
    , actual);
}

test "mkdtemp creates a real directory outside a fixture" {
    const runtime = try helpers.initRuntime(null);
    defer runtime.deinit();

    const source =
        \\import fsp from 'node:fs/promises';
        \\const path = await fsp.mkdtemp('jsz-zig-test-');
        \\const isDir = (await fsp.stat(path)).isDirectory();
        \\await fsp.rmdir(path);
        \\globalThis.__result = path + ':' + isDir;
    ;

    const value = try runtime.evalDetected(source, "<mkdtemp>");
    value.deinit(runtime.context());
    try runtime.run();

    const result = try helpers.readResult(std.testing.allocator, runtime);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "jsz-zig-test-") != null);
    try std.testing.expect(std.mem.endsWith(u8, result, ":true"));
}
