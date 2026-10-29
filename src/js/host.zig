const std = @import("std");
const quickjs = @import("quickjs");
const zio = @import("zio");
const EventLoop = @import("../event_loop.zig").EventLoop;
const Fs = @import("../fs.zig").Fs;
const ChildProcesses = @import("../child_process.zig").ChildProcesses;
const Net = @import("../net.zig").Net;
const Http = @import("../http.zig").Http;
const Fetch = @import("../fetch.zig").Fetch;
const sea = @import("../sea.zig");

pub const Role = enum {
    script,
    main,
    preload,
    renderer,
};

pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ctx: *quickjs.Context,
    loop: *EventLoop,
    out: *std.ArrayList(u8),
    fs: *Fs,
    rt: *zio.Runtime,
    children: *ChildProcesses,
    net: *Net,
    http: *Http,
    fetch: *Fetch,
    /// Which QuickJS context owns this host. `electron` resolves differently
    /// per role, and preload sees only its audited module allowlist.
    role: Role = .script,
    /// Opaque `*desktop.Desktop`; null outside `--desktop`.
    desktop: ?*anyopaque = null,
    /// Logical desktop window owning this context; 0 in the main/script role.
    window_id: u32 = 0,
    /// Borrowed process arguments; owned by the caller that outlives the runtime.
    argv: []const []const u8,
    environ: *std.process.Environ.Map,
    /// Assets embedded by `jszc`; empty outside a single-executable binary.
    assets: []const sea.Asset = &.{},
    /// True when running from a `jszc` payload.
    is_sea: bool = false,
    /// Canonical name of the entry module (absolute path) or null for evals.
    entry: ?[]const u8 = null,
    /// Absolute current working directory; empty until `refreshCwd` succeeds.
    cwd: []const u8 = "",
    /// Set when `cwd` is a host-owned copy; the runtime keeps no second copy.
    cwd_owned: ?[]u8 = null,

    pub fn desktopEnabled(self: *Host) bool {
        return self.desktop != null;
    }

    /// Replaces `cwd` with a host-owned copy of `path`.
    pub fn setCwd(self: *Host, path: []const u8) void {
        self.deinitCwd();
        if (path.len == 0) return;

        const owned = self.allocator.dupe(u8, path) catch return;
        self.cwd_owned = owned;
        self.cwd = owned;
    }

    /// Releases the host-owned copy and clears `cwd`.
    pub fn deinitCwd(self: *Host) void {
        if (self.cwd_owned) |owned| self.allocator.free(owned);
        self.cwd_owned = null;
        self.cwd = "";
    }

    /// Re-reads the process cwd; on failure the previous value stays.
    pub fn refreshCwd(self: *Host) void {
        const path = std.process.currentPathAlloc(self.io, self.allocator) catch return;
        defer self.allocator.free(path);
        self.setCwd(path);
    }
};
