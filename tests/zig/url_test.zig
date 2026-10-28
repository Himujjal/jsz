const std = @import("std");
const helpers = @import("helpers.zig");

fn expectFixture(allocator: std.mem.Allocator, name: []const u8, expected: []const u8) !void {
    const actual = try helpers.runFixture(allocator, name);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "url parses, serializes, and round-trips file URLs" {
    // `file-null` is the one intentional divergence from Node, which accepts
    // NUL bytes inside file URL paths.
    try expectFixture(std.testing.allocator, "url.js",
        \\href=https://a/b?c#d
        \\protocol=https:
        \\host=a
        \\hostname=a
        \\port=""
        \\pathname=/b
        \\search=?c
        \\hash=#d
        \\origin=https://a
        \\relative=https://ex.com/a/x?y
        \\dots=https://ex.com/a/c
        \\credentials=https://user:pa%40ss@ex.com/p
        \\params-href=https://a/b?c=&e=f#d
        \\params-sync=g=h&g=i
        \\params-getall=h,i
        \\params-sort=g=h&g=i
        \\params-size=2
        \\params-delete=g=h
        \\params-entries=g:h
        \\params-keys=g
        \\params-values=h
        \\params-set=g=h&x=a+b
        \\params-href2=https://a/b?g=h&x=a+b#d
        \\sp-string=a=1&a=2&b=
        \\sp-get=1
        \\sp-getall=1,2
        \\sp-has=true:true
        \\sp-object=a=1&b=two+words&c=undefined
        \\sp-iterable=a=1&a=2
        \\sp-plus=a b
        \\sp-unicode=q=%E2%9C%93
        \\default-http="":http://a/
        \\default-https=https://a/x
        \\keep-custom=https://a:8443/x
        \\origin-file=null
        \\origin-data=null
        \\origin-ws=ws://a
        \\canparse-ok=true
        \\canparse-bad=false
        \\canparse-base=true
        \\canparse-badbase=false
        \\parse-ok=https://a/b
        \\parse-bad=null
        \\invalid=TypeError:ERR_INVALID_URL:Invalid URL:nope
        \\file-url=file:///tmp/a%20b%23c%3Fd%25
        \\file-url-instance=true
        \\file-url-relative=true
        \\file-path=/tmp/a b
        \\file-path-roundtrip=/tmp/x y
        \\file-path-localhost=/tmp/x
        \\file-scheme=ERR_INVALID_URL_SCHEME
        \\file-host=ERR_INVALID_FILE_URL_HOST
        \\file-encoded-slash=ERR_INVALID_FILE_URL_PATH
        \\file-null=ERR_INVALID_FILE_URL_PATH
        \\http-options=https:|a|8443|/x?y|user:pa@ss|https://user:pa%40ss@a:8443/x?y#z
        \\default-export=function,function,function,function,function
        \\string=true
        \\json="https://a/b?g=h&x=a+b#d"
        \\
    );
}
