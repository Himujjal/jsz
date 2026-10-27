const std = @import("std");
const quickjs = @import("quickjs");
const zio = @import("zio");
const jobs = @import("jobs.zig");

pub const max_read_bytes = 64 * 1024 * 1024;

pub const Op = enum {
    read_file,
    write_file,
    append_file,
    stat,
    readdir,
    mkdir,
    remove,
    rename,
    copy_file,
    access,
    realpath,
    readlink,
    symlink,
    truncate,
    chmod,
    chown,
    utimes,
    hard_link,
};

pub const ErrorCode = enum {
    noent,
    eacces,
    eexist,
    eisdir,
    enotdir,
    enotempty,
    einval,
    eloop,
    enametoolong,
    enospc,
    efbig,
    erofs,
    emfile,
    enfile,
    eio,

    pub fn text(self: ErrorCode) [:0]const u8 {
        return switch (self) {
            .noent => "ENOENT",
            .eacces => "EACCES",
            .eexist => "EEXIST",
            .eisdir => "EISDIR",
            .enotdir => "ENOTDIR",
            .enotempty => "ENOTEMPTY",
            .einval => "EINVAL",
            .eloop => "ELOOP",
            .enametoolong => "ENAMETOOLONG",
            .enospc => "ENOSPC",
            .efbig => "EFBIG",
            .erofs => "EROFS",
            .emfile => "EMFILE",
            .enfile => "ENFILE",
            .eio => "EIO",
        };
    }

    pub fn message(self: ErrorCode) [:0]const u8 {
        return switch (self) {
            .noent => "no such file or directory",
            .eacces => "permission denied",
            .eexist => "file already exists",
            .eisdir => "illegal operation on a directory",
            .enotdir => "not a directory",
            .enotempty => "directory not empty",
            .einval => "invalid argument",
            .eloop => "too many symbolic links encountered",
            .enametoolong => "name too long",
            .enospc => "no space left on device",
            .efbig => "file too large",
            .erofs => "read-only file system",
            .emfile => "too many open files",
            .enfile => "file table overflow",
            .eio => "i/o error",
        };
    }

    pub fn errno(self: ErrorCode) i32 {
        return switch (self) {
            .noent => -2,
            .eio => -5,
            .eacces => -13,
            .eexist => -17,
            .enotdir => -20,
            .eisdir => -21,
            .einval => -22,
            .enfile => -23,
            .emfile => -24,
            .efbig => -27,
            .enospc => -28,
            .erofs => -30,
            .eloop => -62,
            .enametoolong => -63,
            .enotempty => -66,
        };
    }
};

pub const StatData = struct {
    size: u64,
    mode: u32,
    ino: u64,
    nlink: u64,
    atime_ms: f64,
    mtime_ms: f64,
    ctime_ms: f64,
    birthtime_ms: f64,
    kind: std.Io.File.Kind,
};

pub const EntryData = struct {
    name: []u8,
    kind: std.Io.File.Kind,
};

pub const Outcome = union(enum) {
    none,
    bytes: [:0]u8,
    text: [:0]u8,
    stat: StatData,
    entries: []EntryData,
    path: [:0]u8,
};

pub const Job = struct {
    op: Op,
    allocator: std.mem.Allocator = undefined,
    path: []u8 = &.{},
    path2: []u8 = &.{},
    data: []u8 = &.{},
    path2_owned: bool = false,
    data_owned: bool = false,
    as_text: bool = false,
    recursive: bool = false,
    force: bool = false,
    follow: bool = true,
    exclusive: bool = false,
    dir_only: bool = false,
    access_mode: u8 = 0,
    mode: u32 = 0o666,
    length: u64 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    atime_ms: f64 = 0,
    mtime_ms: f64 = 0,
    resolve: quickjs.Value = .undefined,
    reject: quickjs.Value = .undefined,
    outcome: Outcome = .none,
    err: ?ErrorCode = null,
    /// Completion-queue node; `context` points back at this job.
    link: jobs.Job = undefined,

    /// Frees Zig memory only. QuickJS values are released by the caller with a
    /// context, either after settling or while aborting.
    pub fn free(self: *Job, allocator: std.mem.Allocator) void {
        self.freeFields(allocator);
        allocator.destroy(self);
    }

    pub fn freeFields(self: *Job, allocator: std.mem.Allocator) void {
        if (self.path.len > 0) allocator.free(self.path);
        if (self.path2_owned) allocator.free(self.path2);
        if (self.data_owned) allocator.free(self.data);
        switch (self.outcome) {
            .none, .stat => {},
            .bytes => |bytes| allocator.free(bytes),
            .text => |text| allocator.free(text),
            .path => |path| allocator.free(path),
            .entries => |entries| {
                for (entries) |entry| allocator.free(entry.name);
                allocator.free(entries);
            },
        }
    }
};

/// Owns the async fs worker queue. Jobs run in zio tasks and report back here;
/// only the JS thread touches QuickJS values.
pub const Fs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    rt: *zio.Runtime,
    queue: jobs.Queue,

    pub fn init(allocator: std.mem.Allocator, rt: *zio.Runtime) Fs {
        return .{
            .allocator = allocator,
            .io = rt.io(),
            .rt = rt,
            .queue = jobs.Queue.init(allocator),
        };
    }

    pub fn submit(self: *Fs, job: *Job) !void {
        job.allocator = self.allocator;
        job.link = .{
            .context = job,
            .settle = settleJob,
            .abort = abortJob,
        };

        try self.queue.submit(&job.link);

        _ = self.rt.spawn(runJob, .{ self, job }) catch |err| {
            // The task never started, so the job must not stay pending.
            self.queue.cancel();
            return err;
        };
    }

    fn runJob(self: *Fs, job: *Job) void {
        job.outcome = self.execute(job) catch |err| {
            job.err = mapError(err);
            self.queue.complete(&job.link);
            return;
        };
        self.queue.complete(&job.link);
    }

    pub fn hasWork(self: *Fs) bool {
        return self.queue.hasWork();
    }

    /// Waits for a completion. A null timeout blocks until one arrives.
    pub fn wait(self: *Fs, timeout_ns: ?u64) void {
        self.queue.wait(timeout_ns);
    }

    /// Settles every completed job on the JS thread, then frees it.
    pub fn dispatch(self: *Fs, ctx: *quickjs.Context) void {
        self.queue.dispatch(ctx);
    }

    /// Stops accepting jobs, waits for in-flight work, and frees leftovers.
    pub fn deinit(self: *Fs, ctx: *quickjs.Context) void {
        self.queue.shutdown(ctx);
        self.queue.deinit();
    }

    fn execute(self: *Fs, job: *Job) !Outcome {
        const cwd = std.Io.Dir.cwd();
        switch (job.op) {
            .read_file => {
                const bytes = try cwd.readFileAllocOptions(
                    self.io,
                    job.path,
                    self.allocator,
                    .limited(max_read_bytes),
                    .of(u8),
                    0,
                );
                if (job.as_text) return .{ .text = bytes };
                return .{ .bytes = bytes };
            },
            .write_file, .append_file => {
                if (job.op == .append_file) {
                    const existing = cwd.readFileAllocOptions(
                        self.io,
                        job.path,
                        self.allocator,
                        .limited(max_read_bytes),
                        .of(u8),
                        0,
                    ) catch |err| switch (err) {
                        error.FileNotFound => try self.allocator.allocSentinel(u8, 0, 0),
                        else => return err,
                    };
                    defer self.allocator.free(existing);

                    const combined = try self.allocator.alloc(u8, existing.len + job.data.len);
                    defer self.allocator.free(combined);
                    @memcpy(combined[0..existing.len], existing);
                    @memcpy(combined[existing.len..], job.data);

                    try cwd.writeFile(self.io, .{
                        .sub_path = job.path,
                        .data = combined,
                        .flags = .{ .truncate = true },
                    });
                } else {
                    try cwd.writeFile(self.io, .{
                        .sub_path = job.path,
                        .data = job.data,
                        .flags = .{ .truncate = true, .exclusive = job.exclusive },
                    });
                }
                return .none;
            },
            .stat => {
                const stat = try cwd.statFile(self.io, job.path, .{ .follow_symlinks = job.follow });
                return .{ .stat = statData(stat) };
            },
            .readdir => {
                var dir = try cwd.openDir(self.io, job.path, .{ .iterate = true });
                defer dir.close(self.io);

                var entries: std.ArrayList(EntryData) = .empty;
                errdefer {
                    for (entries.items) |entry| self.allocator.free(entry.name);
                    entries.deinit(self.allocator);
                }

                var iterator = dir.iterate();
                while (try iterator.next(self.io)) |entry| {
                    const name = try self.allocator.dupe(u8, entry.name);
                    errdefer self.allocator.free(name);
                    try entries.append(self.allocator, .{ .name = name, .kind = entry.kind });
                }

                const owned = try entries.toOwnedSlice(self.allocator);
                std.mem.sort(EntryData, owned, {}, lessThanEntry);
                return .{ .entries = owned };
            },
            .mkdir => {
                if (job.recursive) {
                    try cwd.createDirPath(self.io, job.path);
                } else {
                    try cwd.createDir(self.io, job.path, @fromBackingInt(@intCast(job.mode)));
                }
                return .none;
            },
            .remove => {
                if (job.recursive) {
                    cwd.deleteTree(self.io, job.path) catch |err| {
                        if (job.force and err == error.FileNotFound) return .none;
                        return err;
                    };
                    return .none;
                }

                if (job.dir_only) {
                    cwd.deleteDir(self.io, job.path) catch |err| {
                        if (job.force and err == error.FileNotFound) return .none;
                        return err;
                    };
                    return .none;
                }

                cwd.deleteFile(self.io, job.path) catch |err| {
                    if (job.force and err == error.FileNotFound) return .none;
                    return err;
                };
                return .none;
            },
            .rename => {
                try std.Io.Dir.rename(cwd, job.path, cwd, job.path2, self.io);
                return .none;
            },
            .copy_file => {
                try cwd.copyFile(job.path, cwd, job.path2, self.io, .{
                    .replace = !job.exclusive,
                });
                return .none;
            },
            .access => {
                try cwd.access(self.io, job.path, .{
                    .read = job.access_mode & 4 != 0,
                    .write = job.access_mode & 2 != 0,
                    .execute = job.access_mode & 1 != 0,
                    .follow_symlinks = true,
                });
                return .none;
            },
            .realpath => {
                const resolved = try cwd.realPathFileAlloc(self.io, job.path, self.allocator);
                return .{ .path = resolved };
            },
            .readlink => {
                var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const len = try cwd.readLink(self.io, job.path, &buffer);
                return .{ .path = try self.allocator.dupeSentinel(u8, buffer[0..len], 0) };
            },
            .symlink => {
                try cwd.symLink(self.io, job.path2, job.path, .{});
                return .none;
            },
            .truncate => {
                const file = try cwd.openFile(self.io, job.path, .{ .mode = .read_write });
                defer file.close(self.io);
                try file.setLength(self.io, job.length);
                return .none;
            },
            .chmod => {
                try cwd.setFilePermissions(self.io, job.path, @fromBackingInt(@intCast(job.mode)), .{});
                return .none;
            },
            .chown => {
                try cwd.setFileOwner(
                    self.io,
                    job.path,
                    @intCast(job.uid),
                    @intCast(job.gid),
                    .{},
                );
                return .none;
            },
            .hard_link => {
                try cwd.hardLink(job.path, cwd, job.path2, self.io, .{});
                return .none;
            },
            .utimes => {
                try cwd.setTimestamps(self.io, job.path, .{
                    .access_timestamp = .{ .new = .{ .nanoseconds = millisToNanos(job.atime_ms) } },
                    .modify_timestamp = .{ .new = .{ .nanoseconds = millisToNanos(job.mtime_ms) } },
                });
                return .none;
            },
        }
    }
};

fn lessThanEntry(_: void, a: EntryData, b: EntryData) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Rejects the job's promise with the failure or settles it with the outcome.
fn settleJob(ctx: *quickjs.Context, link: *jobs.Job) void {
    const job: *Job = @ptrCast(@alignCast(link.context));
    defer {
        job.resolve.deinit(ctx);
        job.reject.deinit(ctx);
        job.free(job.allocator);
    }

    if (job.err) |code| {
        const error_value = makeError(ctx, code, job);
        defer error_value.deinit(ctx);
        const ignored = job.reject.call(ctx, .undefined, &.{error_value});
        ignored.deinit(ctx);
        return;
    }

    const value = toValue(ctx, job) catch {
        const error_value = makeError(ctx, .eio, job);
        defer error_value.deinit(ctx);
        const ignored = job.reject.call(ctx, .undefined, &.{error_value});
        ignored.deinit(ctx);
        return;
    };
    defer value.deinit(ctx);

    const ignored = job.resolve.call(ctx, .undefined, &.{value});
    ignored.deinit(ctx);
}

/// Drops a job that never got to settle, releasing its QuickJS values.
fn abortJob(ctx: *quickjs.Context, link: *jobs.Job) void {
    const job: *Job = @ptrCast(@alignCast(link.context));
    job.resolve.deinit(ctx);
    job.reject.deinit(ctx);
    job.free(job.allocator);
}

fn millisToNanos(ms: f64) i96 {
    if (std.math.isNan(ms) or ms <= 0) return 0;
    return @intFromFloat(ms * std.time.ns_per_ms);
}

fn statData(stat: std.Io.File.Stat) StatData {
    return .{
        .size = stat.size,
        .mode = kindMode(stat.kind) | @as(u32, @backingInt(stat.permissions)),
        .ino = @intCast(stat.inode),
        .nlink = @intCast(stat.nlink),
        .atime_ms = if (stat.atime) |atime| @floatFromInt(atime.toMilliseconds()) else 0,
        .mtime_ms = @floatFromInt(stat.mtime.toMilliseconds()),
        .ctime_ms = @floatFromInt(stat.ctime.toMilliseconds()),
        .birthtime_ms = @floatFromInt(stat.ctime.toMilliseconds()),
        .kind = stat.kind,
    };
}

fn kindMode(kind: std.Io.File.Kind) u32 {
    return switch (kind) {
        .file => 0o100000,
        .directory => 0o040000,
        .sym_link => 0o120000,
        .named_pipe => 0o010000,
        .unix_domain_socket => 0o140000,
        .block_device => 0o060000,
        .character_device => 0o020000,
        else => 0,
    };
}

fn mapError(err: anyerror) ErrorCode {
    return switch (err) {
        error.FileNotFound => .noent,
        error.AccessDenied, error.PermissionDenied => .eacces,
        error.PathAlreadyExists => .eexist,
        error.IsDir => .eisdir,
        error.NotDir => .enotdir,
        error.DirNotEmpty => .enotempty,
        error.BadPathName, error.InvalidUtf8, error.InvalidWtf8, error.InvalidArgument => .einval,
        error.SymLinkLoop => .eloop,
        error.NameTooLong => .enametoolong,
        error.NoSpaceLeft => .enospc,
        error.FileTooBig => .efbig,
        error.ReadOnlyFileSystem => .erofs,
        error.ProcessFdQuotaExceeded => .emfile,
        error.SystemFdQuotaExceeded => .enfile,
        else => .eio,
    };
}

fn toValue(ctx: *quickjs.Context, job: *Job) !quickjs.Value {
    return switch (job.outcome) {
        .none => .undefined,
        .text => |text| quickjs.Value.initStringLen(ctx, text),
        .bytes => |bytes| quickjs.Value.initUint8ArrayCopy(ctx, bytes),
        .path => |path| quickjs.Value.initStringLen(ctx, path),
        .stat => |stat| statValue(ctx, stat),
        .entries => |entries| entriesValue(ctx, entries),
    };
}

fn statValue(ctx: *quickjs.Context, stat: StatData) !quickjs.Value {
    const object = quickjs.Value.initObject(ctx);
    errdefer object.deinit(ctx);

    try object.setPropertyStr(ctx, "size", quickjs.Value.initFloat64(@floatFromInt(stat.size)));
    try object.setPropertyStr(ctx, "mode", quickjs.Value.initInt64(@intCast(stat.mode)));
    try object.setPropertyStr(ctx, "ino", quickjs.Value.initFloat64(@floatFromInt(stat.ino)));
    try object.setPropertyStr(ctx, "nlink", quickjs.Value.initFloat64(@floatFromInt(stat.nlink)));
    try object.setPropertyStr(ctx, "atimeMs", quickjs.Value.initFloat64(stat.atime_ms));
    try object.setPropertyStr(ctx, "mtimeMs", quickjs.Value.initFloat64(stat.mtime_ms));
    try object.setPropertyStr(ctx, "ctimeMs", quickjs.Value.initFloat64(stat.ctime_ms));
    try object.setPropertyStr(ctx, "birthtimeMs", quickjs.Value.initFloat64(stat.birthtime_ms));
    try object.setPropertyStr(ctx, "kind", quickjs.Value.initString(ctx, kindName(stat.kind)));
    return object;
}

fn entriesValue(ctx: *quickjs.Context, entries: []const EntryData) !quickjs.Value {
    const array = quickjs.Value.initArray(ctx);
    errdefer array.deinit(ctx);

    for (entries, 0..) |entry, index| {
        const item = quickjs.Value.initObject(ctx);
        errdefer item.deinit(ctx);
        try item.setPropertyStr(ctx, "name", quickjs.Value.initStringLen(ctx, entry.name));
        try item.setPropertyStr(ctx, "kind", quickjs.Value.initString(ctx, kindName(entry.kind)));
        try array.setPropertyUint32(ctx, @intCast(index), item);
    }
    return array;
}

fn kindName(kind: std.Io.File.Kind) [:0]const u8 {
    return switch (kind) {
        .file => "file",
        .directory => "dir",
        .sym_link => "symlink",
        .named_pipe => "fifo",
        .unix_domain_socket => "socket",
        .block_device => "block",
        .character_device => "char",
        else => "unknown",
    };
}

fn makeError(ctx: *quickjs.Context, code: ErrorCode, job: *Job) quickjs.Value {
    var buffer: [1024]u8 = undefined;
    const message: []const u8 = std.fmt.bufPrint(
        &buffer,
        "{s}: {s}, {s} '{s}'",
        .{ code.text(), code.message(), opSyscall(job.op), job.path },
    ) catch code.message();

    const global = ctx.getGlobalObject();
    defer global.deinit(ctx);
    const error_ctor = global.getPropertyStr(ctx, "Error");
    defer error_ctor.deinit(ctx);

    const message_value = quickjs.Value.initStringLen(ctx, message);
    defer message_value.deinit(ctx);

    var error_object = if (error_ctor.isFunction(ctx)) blk: {
        var ctor_args = [_]quickjs.c.JSValue{message_value.cval()};
        const raw = quickjs.c.JS_CallConstructor(
            ctx.cval(),
            error_ctor.cval(),
            @intCast(ctor_args.len),
            &ctor_args,
        );
        break :blk quickjs.Value.fromCVal(raw);
    } else quickjs.Value.initObject(ctx);

    if (error_object.isException()) {
        error_object.deinit(ctx);
        error_object = quickjs.Value.initObject(ctx);
    }

    error_object.setPropertyStr(ctx, "code", quickjs.Value.initString(ctx, code.text())) catch {};
    error_object.setPropertyStr(ctx, "errno", quickjs.Value.initInt32(code.errno())) catch {};
    error_object.setPropertyStr(ctx, "syscall", quickjs.Value.initString(ctx, opSyscall(job.op))) catch {};
    error_object.setPropertyStr(ctx, "path", quickjs.Value.initStringLen(ctx, job.path)) catch {};
    return error_object;
}

fn opSyscall(op: Op) [:0]const u8 {
    return switch (op) {
        .read_file => "open",
        .write_file, .append_file => "open",
        .stat => "stat",
        .readdir => "scandir",
        .mkdir => "mkdir",
        .remove => "unlink",
        .rename => "rename",
        .copy_file => "copyfile",
        .access => "access",
        .realpath => "realpath",
        .readlink => "readlink",
        .symlink => "symlink",
        .truncate => "open",
        .chmod => "chmod",
        .chown => "chown",
        .utimes => "utime",
        .hard_link => "link",
    };
}
