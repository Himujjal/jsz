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
    mkdtemp,
    open,
    close,
    read_fd,
    write_fd,
    fsync,
    fstat,
    ftruncate,
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
    ebadf,

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
            .ebadf => "EBADF",
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
            .ebadf => "bad file descriptor",
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
            .ebadf => -9,
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
    fd: i32,
    count: u64,
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
    /// Descriptor operations; `-1` means no descriptor was supplied.
    fd: i32 = -1,
    /// `-1` reads/writes at the descriptor's current offset.
    position: i64 = -1,
    append: bool = false,
    readable: bool = false,
    writable: bool = false,
    create: bool = false,
    truncate_on_open: bool = false,
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
            .none, .stat, .fd, .count => {},
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

/// Runs async fs jobs in zio tasks and reports them to the runtime's shared
/// completion queue; only the JS thread touches QuickJS values.
pub const Fs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    rt: *zio.Runtime,
    queue: *jobs.Queue,

    pub fn init(allocator: std.mem.Allocator, rt: *zio.Runtime, queue: *jobs.Queue) Fs {
        return .{
            .allocator = allocator,
            .io = rt.io(),
            .rt = rt,
            .queue = queue,
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
            .mkdtemp => {
                // zio owns the random suffix; the parent directory is the
                // system temp dir, and `keep` stops `deinit` from deleting it.
                var temp = try zio.createTempDir(.{ .prefix = job.path });
                defer temp.deinit();

                var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const resolved = try temp.parent.realPathFile(temp.name(), &buffer);
                const path = try self.allocator.dupeSentinel(u8, resolved, 0);
                temp.keep();
                return .{ .path = path };
            },
            .open => {
                const permissions: std.Io.File.Permissions = @fromBackingInt(@intCast(job.mode));
                if (job.create) {
                    const file = try cwd.createFile(self.io, job.path, .{
                        .read = job.readable,
                        .truncate = job.truncate_on_open,
                        .exclusive = job.exclusive,
                        .permissions = permissions,
                    });
                    return .{ .fd = file.handle };
                }

                const file = try cwd.openFile(self.io, job.path, .{
                    .mode = if (job.writable) .read_write else .read_only,
                });
                return .{ .fd = file.handle };
            },
            .close => {
                if (job.fd < 0) return error.BadFileDescriptor;
                // `File.close` reports nothing, so a stale descriptor is only
                // observable through the guarded JS wrapper.
                wrapFd(job.fd).close(self.io);
                return .none;
            },
            .read_fd => {
                if (job.fd < 0) return error.BadFileDescriptor;
                if (job.length > max_read_bytes) return error.FileTooBig;

                const length: usize = @intCast(job.length);
                const buffer = try self.allocator.allocSentinel(u8, length, 0);
                errdefer self.allocator.free(buffer);
                if (length == 0) return .{ .bytes = buffer };

                const file = wrapFd(job.fd);
                const count = if (job.position >= 0)
                    try file.readPositional(self.io, &.{buffer}, @intCast(job.position))
                else
                    file.readStreaming(self.io, &.{buffer}) catch |err| switch (err) {
                        error.EndOfStream => 0,
                        else => return err,
                    };

                if (count == length) return .{ .bytes = buffer };

                const short = try self.allocator.allocSentinel(u8, count, 0);
                @memcpy(short[0..count], buffer[0..count]);
                self.allocator.free(buffer);
                return .{ .bytes = short };
            },
            .write_fd => {
                if (job.fd < 0) return error.BadFileDescriptor;
                if (job.data.len == 0) return .{ .count = 0 };

                const file = wrapFd(job.fd);
                const count = if (job.append) blk: {
                    // Appending without O_APPEND: write at the current end of
                    // the file. The runtime is single-threaded, so a stat per
                    // write is enough to concatenate writes.
                    const end = file.length(self.io) catch |err| switch (err) {
                        error.Unexpected => return error.BadFileDescriptor,
                        else => return err,
                    };
                    break :blk try file.writePositional(self.io, &.{job.data}, end);
                } else if (job.position >= 0)
                    try file.writePositional(self.io, &.{job.data}, @intCast(job.position))
                else
                    try file.writeStreaming(self.io, job.data, &.{}, 0);

                return .{ .count = count };
            },
            .fsync => {
                if (job.fd < 0) return error.BadFileDescriptor;
                const file = wrapFd(job.fd);
                // zio logs undocumented errnos for fsync/ftruncate, so check the
                // descriptor first and report a clean EBADF instead.
                try checkFd(file, self.io);
                file.sync(self.io) catch |err| switch (err) {
                    error.Unexpected => return error.BadFileDescriptor,
                    else => return err,
                };
                return .none;
            },
            .fstat => {
                if (job.fd < 0) return error.BadFileDescriptor;
                const stat = wrapFd(job.fd).stat(self.io) catch |err| switch (err) {
                    error.Unexpected => return error.BadFileDescriptor,
                    else => return err,
                };
                return .{ .stat = statData(stat) };
            },
            .ftruncate => {
                if (job.fd < 0) return error.BadFileDescriptor;
                const file = wrapFd(job.fd);
                try checkFd(file, self.io);
                file.setLength(self.io, job.length) catch |err| switch (err) {
                    error.Unexpected => return error.BadFileDescriptor,
                    else => return err,
                };
                return .none;
            },
        }
    }
};

/// Wraps a raw descriptor so `std.Io.File` operations work inside the I/O task.
/// The handle is borrowed: the wrapper never outlives the single syscall and the
/// descriptor stays owned by the JS wrapper.
fn wrapFd(fd: std.Io.File.Handle) std.Io.File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// `stat` is the cheapest zio call that reports a closed descriptor as
/// `error.Unexpected` without logging an undocumented errno.
fn checkFd(file: std.Io.File, io: std.Io) !void {
    _ = file.stat(io) catch |err| switch (err) {
        error.Unexpected => return error.BadFileDescriptor,
        else => |e| return e,
    };
}

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
        error.BadFileDescriptor, error.NotOpenForReading, error.NotOpenForWriting => .ebadf,
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
        .fd => |fd| quickjs.Value.initInt32(fd),
        .count => |count| quickjs.Value.initFloat64(@floatFromInt(count)),
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
    const has_path = job.path.len > 0;
    const message: []const u8 = if (has_path)
        std.fmt.bufPrint(
            &buffer,
            "{s}: {s}, {s} '{s}'",
            .{ code.text(), code.message(), opSyscall(job.op), job.path },
        ) catch code.message()
    else
        std.fmt.bufPrint(
            &buffer,
            "{s}: {s}, {s}",
            .{ code.text(), code.message(), opSyscall(job.op) },
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
    if (has_path) {
        error_object.setPropertyStr(ctx, "path", quickjs.Value.initStringLen(ctx, job.path)) catch {};
    }
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
        .mkdtemp => "mkdtemp",
        .open => "open",
        .close => "close",
        .read_fd => "read",
        .write_fd => "write",
        .fsync => "fsync",
        .fstat => "fstat",
        .ftruncate => "ftruncate",
    };
}
