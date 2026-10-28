// Async TCP coordinator.
//
// `net.createServer` and `net.connect` hand every listener and socket to a zio
// task. Data, end, close, and error events cross back to the JS task through
// the shared `jobs.Queue`; QuickJS values are only ever touched on the JS task.
//
// Ownership rules: records are owned by the JS task (created and freed there),
// except accepted sockets, which the accept task inserts so its reader can
// report data before the connection event settles. Handles to zio tasks live
// behind `io_mutex` because both the JS task and the connector task store them.

const std = @import("std");
const quickjs = @import("quickjs");
const zio = @import("zio");
const jobs = @import("jobs.zig");
const Host = @import("js/host.zig").Host;
const EventLoop = @import("event_loop.zig").EventLoop;

const Allocator = std.mem.Allocator;
const Value = quickjs.Value;

pub const Family = enum { ipv4, ipv6 };

pub fn familyName(family: Family) []const u8 {
    return switch (family) {
        .ipv4 => "IPv4",
        .ipv6 => "IPv6",
    };
}

/// Formatted endpoint text plus port; inline so dispatching an event never
/// needs an allocation that could fail on the I/O task.
pub const AddrText = struct {
    buf: [64]u8 = undefined,
    len: u8 = 0,
    port: u16 = 0,
    family: Family = .ipv4,

    pub fn slice(self: *const AddrText) []const u8 {
        return self.buf[0..self.len];
    }

    fn fromAddress(addr: zio.net.Address) AddrText {
        var result: AddrText = .{};
        var tmp: [96]u8 = undefined;
        var writer = std.Io.Writer.fixed(&tmp);
        addr.format(&writer) catch {};
        const full = writer.buffered();

        // zio appends `:port`; the bracketed IPv6 form makes the last colon
        // unambiguous, so the port never leaks into the address text.
        var text = full;
        if (std.mem.lastIndexOfScalar(u8, text, ':')) |cut| text = text[0..cut];
        // Node reports IPv6 addresses without the URL brackets.
        if (text.len >= 2 and text[0] == '[' and text[text.len - 1] == ']') {
            text = text[1 .. text.len - 1];
        }
        const length = @min(text.len, result.buf.len);
        @memcpy(result.buf[0..length], text[0..length]);
        result.len = @intCast(length);

        switch (addr.getType()) {
            .ip => {
                result.port = addr.ip.getPort();
                result.family = switch (addr.getFamily()) {
                    .ipv4 => .ipv4,
                    .ipv6 => .ipv6,
                    .unix => .ipv4,
                };
            },
            .unix => {},
        }
        return result;
    }

    fn fromIp(addr: zio.net.IpAddress) AddrText {
        return fromAddress(.{ .ip = addr });
    }
};

/// Node-shaped socket error, built without heap allocation.
pub const ErrorInfo = struct {
    code: [:0]const u8,
    errno: i32,
    syscall: [:0]const u8,
    buf: [160]u8 = undefined,
    len: u8 = 0,

    pub fn message(self: *const ErrorInfo) []const u8 {
        return self.buf[0..self.len];
    }
};

const MappedError = struct {
    code: [:0]const u8,
    errno: i32,
};

pub fn mapError(err: anyerror) MappedError {
    return switch (err) {
        error.AddressInUse => .{ .code = "EADDRINUSE", .errno = -48 },
        error.AccessDenied, error.BlockedByFirewall => .{ .code = "EACCES", .errno = -13 },
        error.ConnectionRefused => .{ .code = "ECONNREFUSED", .errno = -61 },
        error.UnknownHostName, error.HostLacksNetworkAddresses => .{ .code = "ENOTFOUND", .errno = -1 },
        error.ConnectionResetByPeer, error.ConnectionAborted => .{ .code = "ECONNRESET", .errno = -54 },
        error.NetworkUnreachable, error.NetworkDown => .{ .code = "ENETUNREACH", .errno = -51 },
        error.HostUnreachable => .{ .code = "EHOSTUNREACH", .errno = -65 },
        error.Timeout => .{ .code = "ETIMEDOUT", .errno = -60 },
        error.Canceled => .{ .code = "ECANCELED", .errno = -89 },
        error.AddressUnavailable, error.AddressFamilyUnsupported, error.SocketNotListening => .{
            .code = "EADDRNOTAVAIL",
            .errno = -49,
        },
        else => .{ .code = "EIO", .errno = -5 },
    };
}

/// Builds `connect ECONNREFUSED 127.0.0.1:80`-style details for the JS facade.
fn makeError(err: anyerror, syscall: [:0]const u8, target: []const u8) ErrorInfo {
    const mapped = mapError(err);
    var info: ErrorInfo = .{ .code = mapped.code, .errno = mapped.errno, .syscall = syscall };
    const separator: []const u8 = if (target.len > 0) " " else "";
    const text = std.fmt.bufPrint(
        &info.buf,
        "{s} {s}{s}{s}",
        .{ syscall, mapped.code, separator, target },
    ) catch "";
    info.len = @intCast(text.len);
    return info;
}

fn failureFor(err: anyerror, syscall: [:0]const u8, host: []const u8, port: u16) ErrorInfo {
    var target_buffer: [96]u8 = undefined;
    const target = std.fmt.bufPrint(&target_buffer, "{s}:{d}", .{ host, port }) catch host;
    return makeError(err, syscall, target);
}

/// Bounded write hand-off. The JS task enqueues owned copies; the writer task
/// owns the stream and drains them in order.
const WriteQueue = struct {
    mutex: zio.Mutex = .init,
    cond: zio.Condition = .init,
    chunks: std.ArrayList([]u8) = .empty,
    bytes: usize = 0,
    limit: usize = 64 * 1024,
    accepting: bool = true,
    eof: bool = false,
    full: bool = false,

    /// Stops accepting new writes but lets the writer drain what is queued.
    fn finish(self: *WriteQueue) void {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        self.accepting = false;
        self.eof = true;
        self.cond.broadcast();
    }

    /// Abandons the queue and releases every buffered chunk.
    fn fail(self: *WriteQueue, allocator: Allocator) void {
        self.mutex.lockUncancelable();
        defer self.mutex.unlock();
        for (self.chunks.items) |chunk| allocator.free(chunk);
        self.chunks.clearRetainingCapacity();
        self.bytes = 0;
        self.accepting = false;
        self.eof = true;
        self.full = false;
        self.cond.broadcast();
    }

    fn deinit(self: *WriteQueue, allocator: Allocator) void {
        for (self.chunks.items) |chunk| allocator.free(chunk);
        self.chunks.deinit(allocator);
        self.chunks = .empty;
        self.bytes = 0;
    }
};

const Server = struct {
    id: u64,
    /// Owned copy of the JS dispatch trampoline; set on the JS task only.
    dispatch: Value = .undefined,
    refs: bool = true,
    closed: std.atomic.Value(bool) = .init(false),
    /// Optional because `closeServer` takes it out before canceling; a second
    /// copy must never be joined.
    handle: ?zio.JoinHandle(void) = null,
    addr: AddrText = .{},
    /// Filled by the listen task before it notifies the waiting JS task.
    failure: ?ErrorInfo = null,
};

const Socket = struct {
    id: u64,
    /// Owned copy of the dispatch trampoline; set on the JS task only.
    dispatch: Value = .undefined,
    has_dispatch: bool = false,
    /// Set for sockets accepted by a server: the connection event duplicates
    /// the server's trampoline into `dispatch` before any socket event settles.
    server_id: u64 = 0,
    refs: bool = true,
    queue: WriteQueue = .{},
    remote: AddrText = .{},
    local: AddrText = .{},
    remote_known: bool = false,
    local_known: bool = false,
    io_mutex: zio.os.Mutex = .init(),
    connector: ?zio.JoinHandle(void) = null,
    reader: ?zio.JoinHandle(void) = null,
    writer: ?zio.JoinHandle(void) = null,
    /// Teardown requested (`destroy`, EOF, or a fatal error).
    closed: std.atomic.Value(bool) = .init(false),
    destroyed: std.atomic.Value(bool) = .init(false),
    had_error: std.atomic.Value(bool) = .init(false),
    close_sent: std.atomic.Value(bool) = .init(false),
};

const Kind = union(enum) {
    connection: struct { socket_id: u64, remote: AddrText, local: AddrText },
    connect: struct { remote: AddrText, local: AddrText },
    data: []u8,
    end,
    drain,
    close: bool,
    failure: ErrorInfo,
};

const NetJob = struct {
    link: jobs.Job,
    owner: *Net,
    id: u64,
    kind: Kind,
};

fn freeKind(allocator: Allocator, kind: Kind) void {
    switch (kind) {
        .data => |bytes| allocator.free(bytes),
        else => {},
    }
}

/// One-shot hand-off from a zio task to the blocking JS task.
const Signal = struct {
    mutex: zio.os.Mutex = .init(),
    cond: zio.os.Condition = .init(),
    done: bool = false,

    fn deinit(self: *Signal) void {
        self.mutex.deinit();
        self.cond.deinit();
    }

    fn notify(self: *Signal) void {
        self.mutex.lock();
        self.done = true;
        self.cond.signal();
        self.mutex.unlock();
    }

    fn wait(self: *Signal) void {
        self.mutex.lock();
        while (!self.done) self.cond.wait(&self.mutex);
        self.mutex.unlock();
    }
};

pub const ListenOutcome = union(enum) {
    ok: struct { id: u64, addr: AddrText },
    failure: ErrorInfo,
};

pub const ConnectOutcome = union(enum) {
    ok: u64,
    failure: ErrorInfo,
};

pub const Net = struct {
    allocator: Allocator,
    io: std.Io,
    rt: *zio.Runtime,
    queue: *jobs.Queue,
    /// Guards both maps and `next_id`; the accept task inserts sockets while the
    /// JS task looks them up.
    map_mutex: zio.os.Mutex = .init(),
    next_id: u64 = 1,
    servers: std.AutoHashMap(u64, *Server),
    sockets: std.AutoHashMap(u64, *Socket),

    pub fn init(
        allocator: Allocator,
        rt: *zio.Runtime,
        queue: *jobs.Queue,
    ) Net {
        return .{
            .allocator = allocator,
            .io = rt.io(),
            .rt = rt,
            .queue = queue,
            .servers = std.AutoHashMap(u64, *Server).init(allocator),
            .sockets = std.AutoHashMap(u64, *Socket).init(allocator),
        };
    }

    // -- record helpers -----------------------------------------------------

    fn nextId(self: *Net) u64 {
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        return id;
    }

    fn getServer(self: *Net, id: u64) ?*Server {
        self.map_mutex.lock();
        defer self.map_mutex.unlock();
        return self.servers.get(id);
    }

    fn getSocket(self: *Net, id: u64) ?*Socket {
        self.map_mutex.lock();
        defer self.map_mutex.unlock();
        return self.sockets.get(id);
    }

    fn takeServer(self: *Net, id: u64) ?*Server {
        self.map_mutex.lock();
        defer self.map_mutex.unlock();
        const entry = self.servers.fetchRemove(id) orelse return null;
        return entry.value;
    }

    fn takeSocket(self: *Net, id: u64) ?*Socket {
        self.map_mutex.lock();
        defer self.map_mutex.unlock();
        const entry = self.sockets.fetchRemove(id) orelse return null;
        return entry.value;
    }

    fn createServer(self: *Net) Allocator.Error!*Server {
        const rec = try self.allocator.create(Server);
        self.map_mutex.lock();
        const id = self.nextId();
        self.map_mutex.unlock();
        rec.* = .{ .id = id };
        self.map_mutex.lock();
        self.servers.put(id, rec) catch |err| {
            self.map_mutex.unlock();
            self.allocator.destroy(rec);
            return err;
        };
        self.map_mutex.unlock();
        return rec;
    }

    /// Inserts a socket record. Called from the accept task, which cannot touch
    /// QuickJS, so the trampoline is attached later by the connection settle.
    fn createAcceptedSocket(self: *Net, server_id: u64) ?*Socket {
        const rec = self.allocator.create(Socket) catch return null;
        self.map_mutex.lock();
        const id = self.nextId();
        rec.* = .{ .id = id, .server_id = server_id };
        self.sockets.put(id, rec) catch {
            self.map_mutex.unlock();
            self.allocator.destroy(rec);
            return null;
        };
        self.map_mutex.unlock();
        return rec;
    }

    // -- events -------------------------------------------------------------

    fn send(self: *Net, id: u64, kind: Kind) bool {
        const job = self.allocator.create(NetJob) catch {
            freeKind(self.allocator, kind);
            return false;
        };
        job.* = .{
            .link = .{
                .context = job,
                .settle = settleJob,
                .abort = abortJob,
            },
            .owner = self,
            .id = id,
            .kind = kind,
        };

        self.queue.submit(&job.link) catch {
            freeKind(self.allocator, kind);
            self.allocator.destroy(job);
            return false;
        };
        self.queue.complete(&job.link);
        return true;
    }

    fn sendData(self: *Net, id: u64, bytes: []const u8) bool {
        const copy = self.allocator.dupe(u8, bytes) catch return false;
        return self.send(id, .{ .data = copy });
    }

    fn sendError(self: *Net, id: u64, info: ErrorInfo) void {
        _ = self.send(id, .{ .failure = info });
    }

    fn sendClose(self: *Net, id: u64, had_error: bool) void {
        _ = self.send(id, .{ .close = had_error });
    }

    /// Emits `close` at most once per socket.
    fn emitClose(self: *Net, rec: *Socket) void {
        if (rec.close_sent.swap(true, .acq_rel)) return;
        self.sendClose(rec.id, rec.had_error.load(.acquire));
    }

    // -- public API (JS task) ----------------------------------------------

    /// Binds synchronously so the facade can return the real port.
    pub fn listen(
        self: *Net,
        ctx: *quickjs.Context,
        host: []const u8,
        port: u16,
        backlog: u31,
        dispatch: Value,
    ) Allocator.Error!ListenOutcome {
        const owned_host = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(owned_host);

        const rec = try self.createServer();
        errdefer {
            _ = self.takeServer(rec.id);
            rec.dispatch.deinit(ctx);
            self.allocator.destroy(rec);
        }
        rec.dispatch = dispatch.dup(ctx);

        var signal: Signal = .{};
        defer signal.deinit();

        rec.handle = self.rt.spawn(listenTask, .{ self, rec, owned_host, port, backlog, &signal }) catch {
            return error.OutOfMemory;
        };

        signal.wait();

        if (rec.failure) |failure| {
            if (rec.handle) |pending| {
                var handle = pending;
                rec.handle = null;
                handle.join();
            }
            _ = self.takeServer(rec.id);
            rec.dispatch.deinit(ctx);
            self.allocator.destroy(rec);
            return .{ .failure = failure };
        }

        return .{ .ok = .{ .id = rec.id, .addr = rec.addr } };
    }

    /// Starts dialing immediately; `connect`/`error` arrive as dispatches.
    pub fn connect(
        self: *Net,
        ctx: *quickjs.Context,
        host: []const u8,
        port: u16,
        dispatch: Value,
    ) Allocator.Error!ConnectOutcome {
        const rec = self.allocator.create(Socket) catch return error.OutOfMemory;
        self.map_mutex.lock();
        const id = self.nextId();
        self.map_mutex.unlock();

        rec.* = .{
            .id = id,
            .dispatch = dispatch.dup(ctx),
            .has_dispatch = true,
        };

        self.map_mutex.lock();
        self.sockets.put(id, rec) catch |err| {
            self.map_mutex.unlock();
            rec.dispatch.deinit(ctx);
            self.allocator.destroy(rec);
            return err;
        };
        self.map_mutex.unlock();

        const owned_host = self.allocator.dupe(u8, host) catch {
            _ = self.takeSocket(id);
            rec.dispatch.deinit(ctx);
            self.allocator.destroy(rec);
            return error.OutOfMemory;
        };

        const handle = self.rt.spawn(connectTask, .{ self, rec, owned_host, port }) catch {
            self.allocator.free(owned_host);
            _ = self.takeSocket(id);
            rec.dispatch.deinit(ctx);
            rec.queue.deinit(self.allocator);
            self.allocator.destroy(rec);
            return error.OutOfMemory;
        };
        rec.io_mutex.lock();
        rec.connector = handle;
        rec.io_mutex.unlock();

        return .{ .ok = id };
    }

    /// `0` accepted, `1` accepted over the high-water mark, `2` closed.
    pub fn write(self: *Net, id: u64, bytes: []const u8) i32 {
        const rec = self.getSocket(id) orelse return 2;
        const queue = &rec.queue;

        queue.mutex.lockUncancelable();
        defer queue.mutex.unlock();

        if (!queue.accepting) return 2;

        const copy = self.allocator.dupe(u8, bytes) catch return 2;
        queue.chunks.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            return 2;
        };
        queue.bytes += copy.len;
        queue.cond.signal();

        if (queue.bytes > queue.limit) {
            queue.full = true;
            return 1;
        }
        return 0;
    }

    pub fn end(self: *Net, id: u64) bool {
        const rec = self.getSocket(id) orelse return false;
        rec.queue.finish();
        return true;
    }

    /// Requests teardown. A still-connecting socket is canceled immediately;
    /// otherwise the reader is canceled so a blocked read returns now.
    pub fn destroy(self: *Net, id: u64) bool {
        const rec = self.getSocket(id) orelse return false;
        if (rec.destroyed.swap(true, .acq_rel)) return true;

        rec.closed.store(true, .release);
        rec.queue.finish();

        // Take the handles out first: `cancel` consumes the awaitable, so a
        // stale copy left in the record would be joined after the fact.
        rec.io_mutex.lock();
        const connector = rec.connector;
        const reader = rec.reader;
        rec.connector = null;
        rec.reader = null;
        rec.io_mutex.unlock();

        if (connector) |pending| {
            var handle = pending;
            handle.cancel();
        }
        if (reader) |pending| {
            var handle = pending;
            handle.cancel();
        }
        return true;
    }

    pub fn closeServer(self: *Net, id: u64) bool {
        const rec = self.getServer(id) orelse return false;
        rec.closed.store(true, .release);

        // The accept task is blocked in `accept(.none)`; canceling the taken
        // handle lets it run `server.close()` and report `close` promptly.
        const handle = rec.handle;
        rec.handle = null;
        if (handle) |pending| {
            var taken = pending;
            taken.cancel();
        }
        return true;
    }

    pub fn setServerRef(self: *Net, id: u64, ref: bool, loop: *EventLoop) bool {
        const rec = self.getServer(id) orelse return false;
        toggleRef(&rec.refs, ref, loop);
        return true;
    }

    pub fn setSocketRef(self: *Net, id: u64, ref: bool, loop: *EventLoop) bool {
        const rec = self.getSocket(id) orelse return false;
        toggleRef(&rec.refs, ref, loop);
        return true;
    }

    /// Local endpoint for sockets, bound endpoint for servers.
    pub fn addressOf(self: *Net, id: u64) ?AddrText {
        if (self.getServer(id)) |rec| return rec.addr;
        if (self.getSocket(id)) |rec| {
            if (rec.local_known) return rec.local;
            if (rec.remote_known) return rec.remote;
        }
        return null;
    }

    /// Stops every listener and socket, joining each task before freeing the
    /// record it may still touch. Runs before `queue.shutdown`.
    pub fn deinit(self: *Net, ctx: *quickjs.Context) void {
        {
            var iterator = self.servers.valueIterator();
            while (iterator.next()) |slot| {
                const rec = slot.*;
                rec.closed.store(true, .release);
                if (rec.handle) |pending| {
                    var handle = pending;
                    rec.handle = null;
                    handle.cancel();
                }
                rec.dispatch.deinit(ctx);
                self.allocator.destroy(rec);
            }
            self.servers.deinit();
        }

        {
            var iterator = self.sockets.valueIterator();
            while (iterator.next()) |slot| {
                const rec = slot.*;
                rec.destroyed.store(true, .release);
                rec.closed.store(true, .release);
                rec.queue.finish();
                self.reapSocket(rec, true);
                rec.queue.deinit(self.allocator);
                if (rec.has_dispatch) rec.dispatch.deinit(ctx);
                self.allocator.destroy(rec);
            }
            self.sockets.deinit();
        }

        self.map_mutex.deinit();
    }

    /// Joins the connector, then the reader, which joins the writer itself
    /// before it returns. `cancel_tasks` is only used during shutdown: a read
    /// blocked in `read(.none)` must not stall teardown.
    fn reapSocket(self: *Net, rec: *Socket, cancel_tasks: bool) void {
        _ = self;

        rec.io_mutex.lock();
        const connector = rec.connector;
        rec.connector = null;
        rec.io_mutex.unlock();

        if (connector) |pending| {
            var handle = pending;
            if (cancel_tasks) handle.cancel() else handle.join();
        }

        // The connector may have published the reader before it finished, so
        // take it only after the connector is settled.
        rec.io_mutex.lock();
        const reader = rec.reader;
        rec.reader = null;
        rec.io_mutex.unlock();
        if (reader) |pending| {
            var handle = pending;
            if (cancel_tasks) handle.cancel() else handle.join();
        }

        // A live reader joins the writer itself and clears the slot.
        rec.io_mutex.lock();
        const writer = rec.writer;
        rec.writer = null;
        rec.io_mutex.unlock();
        if (writer) |pending| {
            var handle = pending;
            handle.join();
        }
    }

    // -- dispatch -----------------------------------------------------------

    fn invoke(
        self: *Net,
        ctx: *quickjs.Context,
        dispatch: Value,
        id: u64,
        event: [*:0]const u8,
        payload: Value,
    ) void {
        _ = self;
        const id_value = Value.initFloat64(@floatFromInt(id));
        defer id_value.deinit(ctx);
        const event_value = Value.initString(ctx, event);
        defer event_value.deinit(ctx);
        defer payload.deinit(ctx);

        const result = dispatch.call(ctx, .undefined, &.{ id_value, event_value, payload });
        defer result.deinit(ctx);
        // Listener errors are rethrown asynchronously by the facade; never let
        // an exception escape this C frame.
        if (result.isException()) clearException(ctx);
    }
};

fn toggleRef(refs: *bool, ref: bool, loop: *EventLoop) void {
    if (refs.* == ref) return;
    refs.* = ref;
    if (ref) loop.ref() else loop.unref();
}

fn clearException(ctx: *quickjs.Context) void {
    const exception = ctx.getException();
    exception.deinit(ctx);
}

fn setField(ctx: *quickjs.Context, object: Value, name: [*:0]const u8, value: Value) bool {
    object.setPropertyStr(ctx, name, value) catch return false;
    return true;
}

fn setAddressFields(
    ctx: *quickjs.Context,
    object: Value,
    addr: AddrText,
    remote: bool,
) void {
    const address_name: [*:0]const u8 = if (remote) "remoteAddress" else "localAddress";
    const port_name: [*:0]const u8 = if (remote) "remotePort" else "localPort";
    _ = setField(ctx, object, address_name, Value.initStringLen(ctx, addr.slice()));
    _ = setField(ctx, object, port_name, Value.initInt32(@intCast(addr.port)));
}

fn buildError(ctx: *quickjs.Context, info: ErrorInfo) Value {
    const object = Value.initObject(ctx);
    if (object.isException()) return object;
    _ = setField(ctx, object, "code", Value.initString(ctx, info.code));
    _ = setField(ctx, object, "message", Value.initStringLen(ctx, info.message()));
    _ = setField(ctx, object, "errno", Value.initInt32(info.errno));
    _ = setField(ctx, object, "syscall", Value.initString(ctx, info.syscall));
    return object;
}

fn settleJob(ctx: *quickjs.Context, link: *jobs.Job) void {
    const job: *NetJob = @ptrCast(@alignCast(link.context));
    const owner = job.owner;
    defer owner.allocator.destroy(job);

    switch (job.kind) {
        .connection => |payload| {
            const server = owner.getServer(job.id) orelse return;
            const socket = owner.getSocket(payload.socket_id) orelse return;

            // The accept task cannot touch QuickJS; duplicate the trampoline on
            // the JS task before any socket event can settle.
            if (!socket.has_dispatch) {
                socket.dispatch = server.dispatch.dup(ctx);
                socket.has_dispatch = true;
            }
            if (ctx.getOpaque(Host)) |host| host.loop.ref();

            var object = Value.initObject(ctx);
            if (object.isException()) {
                clearException(ctx);
                object = Value.null;
            } else {
                _ = setField(ctx, object, "socketId", Value.initFloat64(@floatFromInt(socket.id)));
                setAddressFields(ctx, object, payload.remote, true);
                setAddressFields(ctx, object, payload.local, false);
            }
            owner.invoke(ctx, server.dispatch, server.id, "connection", object);
        },
        .connect => |payload| {
            const socket = owner.getSocket(job.id) orelse return;
            if (!socket.has_dispatch) return;
            // `destroy` may have landed after the dialer queued this event.
            if (socket.destroyed.load(.acquire)) return;
            var object = Value.initObject(ctx);
            if (object.isException()) {
                clearException(ctx);
                object = Value.null;
            } else {
                setAddressFields(ctx, object, payload.remote, true);
                setAddressFields(ctx, object, payload.local, false);
            }
            owner.invoke(ctx, socket.dispatch, job.id, "connect", object);
        },
        .data => |bytes| {
            defer owner.allocator.free(bytes);
            const socket = owner.getSocket(job.id) orelse return;
            if (!socket.has_dispatch) return;
            var payload = Value.initUint8ArrayCopy(ctx, bytes);
            if (payload.isException()) {
                clearException(ctx);
                payload = Value.null;
            }
            owner.invoke(ctx, socket.dispatch, job.id, "data", payload);
        },
        .end => {
            const socket = owner.getSocket(job.id) orelse return;
            if (!socket.has_dispatch) return;
            owner.invoke(ctx, socket.dispatch, job.id, "end", Value.null);
        },
        .drain => {
            const socket = owner.getSocket(job.id) orelse return;
            if (!socket.has_dispatch) return;
            owner.invoke(ctx, socket.dispatch, job.id, "drain", Value.null);
        },
        .failure => |info| {
            const socket = owner.getSocket(job.id) orelse return;
            if (!socket.has_dispatch) return;
            var object = buildError(ctx, info);
            if (object.isException()) {
                clearException(ctx);
                object = Value.null;
            }
            owner.invoke(ctx, socket.dispatch, job.id, "error", object);
        },
        .close => |had_error| {
            if (owner.takeServer(job.id)) |server| {
                if (server.handle) |pending| {
                    var handle = pending;
                    server.handle = null;
                    handle.join();
                }
                if (ctx.getOpaque(Host)) |host| {
                    if (server.refs) host.loop.unref();
                }
                owner.invoke(ctx, server.dispatch, job.id, "close", Value.undefined);
                server.dispatch.deinit(ctx);
                owner.allocator.destroy(server);
                return;
            }
            if (owner.takeSocket(job.id)) |socket| {
                owner.reapSocket(socket, false);
                if (ctx.getOpaque(Host)) |host| {
                    if (socket.refs) host.loop.unref();
                }
                var object = Value.initObject(ctx);
                if (object.isException()) {
                    clearException(ctx);
                    object = Value.null;
                } else {
                    _ = setField(ctx, object, "hadError", Value.initBool(had_error));
                }
                if (socket.has_dispatch) {
                    owner.invoke(ctx, socket.dispatch, job.id, "close", object);
                } else if (!object.isException()) {
                    object.deinit(ctx);
                }
                socket.queue.deinit(owner.allocator);
                if (socket.has_dispatch) socket.dispatch.deinit(ctx);
                owner.allocator.destroy(socket);
            }
        },
    }
}

fn abortJob(_: *quickjs.Context, link: *jobs.Job) void {
    const job: *NetJob = @ptrCast(@alignCast(link.context));
    const owner = job.owner;
    freeKind(owner.allocator, job.kind);
    owner.allocator.destroy(job);
}

// -- tasks (zio thread; never touch QuickJS) --------------------------------

fn isIpAddress(addr: zio.net.Address) bool {
    return switch (addr.any.family) {
        zio.os.net.AF.INET, zio.os.net.AF.INET6 => true,
        else => false,
    };
}

/// `getsockname` on the accepted/connected handle; falls back to the peer.
fn localAddress(stream: zio.net.Stream) ?zio.net.Address {
    var addr: zio.net.Address = undefined;
    var length: zio.os.net.socklen_t = @sizeOf(zio.net.Address);
    zio.os.net.getsockname(stream.socket.handle, &addr.any, &length) catch return null;
    const result = zio.net.Address.fromPosix(&addr.any, length);
    if (!isIpAddress(result)) return null;
    return result;
}

fn listenIp(host: []const u8, port: u16) !zio.net.IpAddress {
    if (host.len == 0) return zio.net.IpAddress.unspecified(port);

    if (zio.net.IpAddress.parseIp(host, port)) |addr| {
        return addr;
    } else |_| {}

    var storage: [8]zio.net.HostName.LookupResult = undefined;
    const name = try zio.net.HostName.init(host);
    const count = try name.lookup(&storage, .{ .port = port });
    for (storage[0..count]) |entry| {
        switch (entry) {
            .address => |addr| return addr,
            .canonical_name => {},
        }
    }
    return error.UnknownHostName;
}

fn listenTask(
    owner: *Net,
    rec: *Server,
    host: []u8,
    port: u16,
    backlog: u31,
    signal: *Signal,
) void {
    const addr = listenIp(host, port) catch |err| {
        rec.failure = failureFor(err, "listen", host, port);
        owner.allocator.free(host);
        signal.notify();
        return;
    };

    const server = addr.listen(.{
        .reuse_address = true,
        .kernel_backlog = backlog,
    }) catch |err| {
        rec.failure = failureFor(err, "listen", host, port);
        owner.allocator.free(host);
        signal.notify();
        return;
    };
    owner.allocator.free(host);

    const bound = server.socket.address;
    rec.addr = if (isIpAddress(bound)) AddrText.fromAddress(bound) else AddrText.fromIp(addr);

    signal.notify();

    while (true) {
        if (rec.closed.load(.acquire)) break;

        const stream = server.accept(.{ .timeout = .none }) catch |err| switch (err) {
            // `closeServer` cancels the accept task to interrupt this wait.
            error.Canceled => break,
            else => {
                owner.sendError(rec.id, makeError(err, "accept", ""));
                break;
            },
        };

        if (rec.closed.load(.acquire)) {
            stream.close();
            break;
        }

        acceptConnection(owner, rec, stream);
    }

    server.close();
    owner.sendClose(rec.id, false);
}

fn acceptStream(host: []const u8, port: u16) !zio.net.Stream {
    if (zio.net.IpAddress.parseIp(host, port)) |addr| {
        return addr.connect(.{ .timeout = .none });
    } else |_| {}

    const name = try zio.net.HostName.init(host);
    return name.connect(port, .{ .timeout = .none });
}

fn acceptConnection(owner: *Net, server: *Server, stream: zio.net.Stream) void {
    const remote = AddrText.fromAddress(stream.socket.address);
    const local = if (localAddress(stream)) |addr| AddrText.fromAddress(addr) else server.addr;

    const socket = owner.createAcceptedSocket(server.id) orelse {
        stream.close();
        return;
    };
    socket.remote = remote;
    socket.local = local;
    socket.remote_known = true;
    socket.local_known = true;

    // Queue the connection event before any data so the facade can attach
    // listeners before the first chunk settles.
    _ = owner.send(server.id, .{ .connection = .{
        .socket_id = socket.id,
        .remote = remote,
        .local = local,
    } });

    startSocketTasks(owner, socket, stream);
}

fn startSocketTasks(owner: *Net, rec: *Socket, stream: zio.net.Stream) void {
    const writer = owner.rt.spawn(writeLoop, .{ owner, rec, stream }) catch {
        rec.had_error.store(true, .release);
        rec.closed.store(true, .release);
        stream.shutdown(.both) catch {};
        stream.close();
        owner.emitClose(rec);
        return;
    };

    // Publish the writer before starting the reader: teardown joins it, and a
    // reader that exits immediately must not close the descriptor underneath a
    // live write.
    rec.io_mutex.lock();
    rec.writer = writer;
    rec.io_mutex.unlock();

    const reader = owner.rt.spawn(readLoop, .{ owner, rec, stream }) catch {
        rec.closed.store(true, .release);
        rec.queue.finish();
        var handle = writer;
        handle.cancel();
        stream.close();
        owner.emitClose(rec);
        return;
    };

    rec.io_mutex.lock();
    rec.reader = reader;
    rec.io_mutex.unlock();
}

fn connectTask(owner: *Net, rec: *Socket, host: []u8, port: u16) void {
    defer owner.allocator.free(host);

    const stream = acceptStream(host, port) catch |err| {
        // `destroy` cancels a still-connecting socket; still settle it so the
        // JS facade sees `close`.
        if (rec.destroyed.load(.acquire)) {
            abandonConnect(owner, rec);
            return;
        }
        if (err == error.Canceled) return;
        owner.sendError(rec.id, failureFor(err, "connect", host, port));
        rec.had_error.store(true, .release);
        rec.closed.store(true, .release);
        rec.queue.fail(owner.allocator);
        owner.emitClose(rec);
        return;
    };

    // A cancel that lands right after connect must still release the stream.
    zio.checkCancel() catch {
        stream.close();
        if (rec.destroyed.load(.acquire)) abandonConnect(owner, rec);
        return;
    };
    if (rec.destroyed.load(.acquire)) {
        stream.shutdown(.both) catch {};
        stream.close();
        abandonConnect(owner, rec);
        return;
    }

    const remote = AddrText.fromAddress(stream.socket.address);
    const local = if (localAddress(stream)) |addr| AddrText.fromAddress(addr) else remote;
    rec.remote = remote;
    rec.local = local;
    rec.remote_known = true;
    rec.local_known = true;

    startSocketTasks(owner, rec, stream);
    _ = owner.send(rec.id, .{ .connect = .{ .remote = remote, .local = local } });
}

/// A destroyed socket never got a writer, so release queued chunks and emit
/// `close` instead of leaving the facade waiting for a `connect`.
fn abandonConnect(owner: *Net, rec: *Socket) void {
    rec.closed.store(true, .release);
    rec.queue.fail(owner.allocator);
    owner.emitClose(rec);
}

fn writeLoop(owner: *Net, rec: *Socket, stream: zio.net.Stream) void {
    const queue = &rec.queue;

    outer: while (true) {
        queue.mutex.lockUncancelable();

        while (queue.chunks.items.len == 0 and !queue.eof) {
            queue.cond.waitUncancelable(&queue.mutex);
        }
        if (queue.chunks.items.len == 0) {
            const eof = queue.eof;
            queue.accepting = false;
            queue.mutex.unlock();
            if (eof) stream.shutdown(.send) catch {};
            break :outer;
        }

        const chunk = queue.chunks.orderedRemove(0);
        queue.bytes -= chunk.len;

        var send_drain = false;
        if (queue.full and queue.bytes < queue.limit) {
            queue.full = false;
            send_drain = true;
        }
        queue.mutex.unlock();

        if (send_drain) _ = owner.send(rec.id, .drain);

        stream.writeAll(chunk, .none) catch |err| {
            owner.allocator.free(chunk);
            if (rec.destroyed.load(.acquire) or err == error.Canceled) {
                queue.fail(owner.allocator);
                return;
            }
            rec.had_error.store(true, .release);
            rec.closed.store(true, .release);
            owner.sendError(rec.id, makeError(err, "write", ""));
            queue.fail(owner.allocator);
            // Wake the reader so it completes the teardown and emits close.
            stream.shutdown(.both) catch {};
            return;
        };
        owner.allocator.free(chunk);
    }
}

fn readLoop(owner: *Net, rec: *Socket, stream: zio.net.Stream) void {
    var buffer: [16 * 1024]u8 = undefined;
    var read_error: ?anyerror = null;

    while (true) {
        if (rec.closed.load(.acquire)) break;

        const count = stream.read(&buffer, .none) catch |err| switch (err) {
            // `destroy` cancels this task to interrupt the blocked read.
            error.Canceled => break,
            else => {
                read_error = err;
                break;
            },
        };
        if (count == 0) break;
        if (!owner.sendData(rec.id, buffer[0..count])) {
            read_error = error.OutOfMemory;
            break;
        }
    }

    if (read_error) |err| {
        if (!rec.destroyed.load(.acquire)) {
            rec.had_error.store(true, .release);
            owner.sendError(rec.id, makeError(err, "read", ""));
        }
    }

    rec.closed.store(true, .release);
    // Stop accepting writes but let the writer flush what is already queued.
    rec.queue.finish();

    const errored = rec.had_error.load(.acquire);
    const destroyed = rec.destroyed.load(.acquire);
    if (!errored and !destroyed) _ = owner.send(rec.id, .end);

    // A graceful EOF must not truncate writes the peer has not read yet; an
    // aborted connection must instead wake a writer blocked in `writeAll`.
    if (errored or destroyed) {
        stream.shutdown(.both) catch {};
    } else {
        stream.shutdown(.receive) catch {};
    }

    // The writer owns the same stream; it must be gone before the descriptor
    // is closed.
    rec.io_mutex.lock();
    const writer = rec.writer;
    rec.writer = null;
    rec.io_mutex.unlock();
    if (writer) |pending| {
        var handle = pending;
        handle.join();
    }

    stream.close();
    owner.emitClose(rec);
}
