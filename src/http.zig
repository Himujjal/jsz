// HTTP server coordinator over `dusty.Server`.
//
// Dusty owns listening, request parsing, keep-alive, and response writing. One
// `dusty.Server(Server)` runs per JS `http.Server`; each request is handed to
// the JS task through the shared completion queue and the handler waits for the
// JS response on a condition variable. QuickJS values never leave the JS task.
//
// Requests are buffered whole (1 MiB cap), matching the facade's non-streaming
// `IncomingMessage`. Responses may be buffered (one write) or streamed chunk by
// chunk through `res.write`; the handler below drains the queue while JS runs.

const std = @import("std");
const builtin = @import("builtin");
const quickjs = @import("quickjs");
const zio = @import("zio");
const dusty = @import("dusty");
const jobs = @import("jobs.zig");
const Host = @import("js/host.zig").Host;

const Value = quickjs.Value;

/// Requests with a larger body are answered with 413 and never reach JS.
const max_body: usize = 1024 * 1024;

/// `streamWrite` reports backpressure above the high-water mark; the handler
/// raises `drain` once the queued bytes fall below the low-water mark.
const high_water: usize = 64 * 1024;
const low_water: usize = 16 * 1024;

const is_darwin = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit => true,
    else => false,
};

fn errnoFor(code: []const u8) i32 {
    if (std.mem.eql(u8, code, "EADDRINUSE")) return if (is_darwin) -48 else -98;
    if (std.mem.eql(u8, code, "EACCES")) return -13;
    if (std.mem.eql(u8, code, "ENOTFOUND")) return -3008;
    if (std.mem.eql(u8, code, "ECONNRESET")) return if (is_darwin) -54 else -104;
    if (std.mem.eql(u8, code, "ETIMEDOUT")) return if (is_darwin) -60 else -110;
    return -5;
}

pub const Failure = struct {
    code: [:0]const u8,
    errno: i32,
    message: []u8,
    syscall: []u8,

    pub fn deinit(self: *Failure, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.syscall);
    }
};

/// Fails a listen with a Node-shaped error; `detail` is the host or address.
fn listenFailure(
    allocator: std.mem.Allocator,
    syscall: []const u8,
    code: [:0]const u8,
    detail: []const u8,
) std.mem.Allocator.Error!Failure {
    const message = if (std.mem.eql(u8, code, "EADDRINUSE"))
        try std.fmt.allocPrint(allocator, "{s} {s}: address already in use {s}", .{ syscall, code, detail })
    else if (std.mem.eql(u8, code, "EACCES"))
        try std.fmt.allocPrint(allocator, "{s} {s}: permission denied {s}", .{ syscall, code, detail })
    else
        try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ syscall, code, detail });
    errdefer allocator.free(message);
    const owned_syscall = try allocator.dupe(u8, syscall);
    return .{
        .code = code,
        .errno = errnoFor(code),
        .message = message,
        .syscall = owned_syscall,
    };
}

fn listenCode(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.AddressInUse => "EADDRINUSE",
        error.AccessDenied, error.PermissionDenied => "EACCES",
        error.AddressNotAvailable, error.AddressFamilyUnsupported => "EADDRNOTAVAIL",
        error.Timeout => "ETIMEDOUT",
        error.NameTooLong, error.InvalidHostName => "ENOTFOUND",
        error.UnknownHostName, error.HostLacksNetworkAddresses => "ENOTFOUND",
        error.TemporaryNameServerFailure, error.NameServerFailure => "ETIMEDOUT",
        else => "EIO",
    };
}

pub const HeaderPair = struct {
    name: []u8,
    value: []u8,
};

const RequestPayload = struct {
    server_id: u64,
    conn_id: u64,
    method: []const u8,
    url: []u8,
    version: []const u8,
    headers: []HeaderPair,
    body: []u8,
    remote_address: []u8,
    remote_port: u16,
    local_address: []u8,
    local_port: u16,
    keep_alive: bool,

    fn deinit(self: *RequestPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        freeHeaders(allocator, self.headers);
        allocator.free(self.body);
        allocator.free(self.remote_address);
        allocator.free(self.local_address);
    }
};

fn freeHeaders(allocator: std.mem.Allocator, headers: []HeaderPair) void {
    for (headers) |pair| {
        allocator.free(pair.name);
        allocator.free(pair.value);
    }
    allocator.free(headers);
}

const Kind = union(enum) {
    request: RequestPayload,
    conn_close: u64,
    server_close: u64,
    /// The response queue drained below the low-water mark.
    drain: u64,
    server_error: struct { server_id: u64, failure: Failure },
};

fn freeKind(allocator: std.mem.Allocator, kind: Kind) void {
    switch (kind) {
        .request => |payload| {
            var copy = payload;
            copy.deinit(allocator);
        },
        .server_error => |entry| {
            var failure = entry.failure;
            failure.deinit(allocator);
        },
        .conn_close, .server_close, .drain => {},
    }
}

/// One JS `http.Server`. `dusty.Server(Server)` borrows `listeners` and `ctx`;
/// both live here, so the record must stay heap-allocated and unmoved.
const Server = struct {
    id: u64,
    owner: *Http,
    dispatch: Value,
    /// Owned copy of the requested host, for failure messages.
    host: []u8,
    /// Owned PEM bytes for an HTTPS listener; empty for plain HTTP.
    tls_cert: []u8 = &.{},
    tls_key: []u8 = &.{},
    tls_ca: []u8 = &.{},
    closed: std.atomic.Value(bool) = .init(false),
    refs: bool = true,
    ready: std.atomic.Value(bool) = .init(false),
    listen_failed: bool = false,
    failure: ?Failure = null,
    run_handle: ?zio.JoinHandle(void) = null,
    ready_handle: ?zio.JoinHandle(void) = null,
    /// Runs the cancel of `run_handle` off the JS task; joining it before the
    /// record is freed keeps the run task's pointer valid.
    stop_handle: ?zio.JoinHandle(void) = null,
    listeners: [1]dusty.Listener = undefined,
    server: dusty.Server(Server) = undefined,
    address_text: []u8 = &.{},
    family: []const u8 = "IPv4",
    port: u16 = 0,
    close_sent: std.atomic.Value(bool) = .init(false),
};

/// Response hand-off for one request. The dusty handler waits on `cond`; the
/// JS task fills the owned buffers through `Http.respond`, or feeds `chunks`
/// through the `stream*` methods.
const ResponseSlot = struct {
    mutex: zio.Mutex = .init,
    cond: zio.Condition = .init,
    ready: bool = false,
    closed: bool = false,
    status: u16 = 200,
    reason: ?[]u8 = null,
    headers: []HeaderPair = &.{},
    body: []u8 = &.{},
    keep_alive: bool = true,
    streaming: bool = false,
    stream_ended: bool = false,
    chunks: std.ArrayList([]u8) = .empty,
    queued_bytes: usize = 0,
    drain_pending: bool = false,

    fn freeBuffers(self: *ResponseSlot, allocator: std.mem.Allocator) void {
        if (self.reason) |text| allocator.free(text);
        freeHeaders(allocator, self.headers);
        allocator.free(self.body);
        for (self.chunks.items) |chunk| allocator.free(chunk);
        self.chunks.deinit(allocator);
        self.chunks = .empty;
        self.queued_bytes = 0;
        self.drain_pending = false;
        self.streaming = false;
        self.reason = null;
        self.headers = &.{};
        self.body = &.{};
    }
};

/// One in-flight request. Dusty keeps the TCP connection; this record only
/// correlates the request job with `res.end`.
const Conn = struct {
    id: u64,
    owner: *Http,
    server: *Server,
    slot: ResponseSlot = .{},
    closed: std.atomic.Value(bool) = .init(false),
    /// Map reference plus one per `respond`; zero frees the record.
    refs: std.atomic.Value(u32) = .init(1),
    remote_address: []u8,
    remote_port: u16,
    local_address: []u8,
    local_port: u16,
};

const HttpJob = struct {
    link: jobs.Job,
    owner: *Http,
    server: *Server,
    kind: Kind,
};

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

pub const AddressInfo = struct {
    address: []const u8,
    family: []const u8,
    port: u16,
};

/// PEM material for an HTTPS listener. Dusty loads and owns the parsed pair.
pub const TlsMaterial = struct {
    cert: []const u8,
    key: []const u8,
    /// PEM certificate authorities for mutual TLS.
    ca: []const u8 = &.{},
    /// Ask connecting clients for a certificate.
    request_cert: bool = false,
    /// Reject a client that presents no certificate or an untrusted one.
    reject_unauthorized: bool = true,
};

pub const ListenResult = union(enum) {
    ok: struct { id: u64, address: []const u8, family: []const u8, port: u16 },
    failure: Failure,
};

pub const Http = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    rt: *zio.Runtime,
    queue: *jobs.Queue,
    /// Both keyed by the same id counter so dispatch can tell them apart.
    servers: std.AutoHashMap(u64, *Server),
    conns: std.AutoHashMap(u64, *Conn),
    /// Shared by dusty handler tasks and the JS task.
    map_mutex: zio.os.Mutex = .init(),
    next_id: std.atomic.Value(u64) = .init(1),

    pub fn init(
        allocator: std.mem.Allocator,
        rt: *zio.Runtime,
        queue: *jobs.Queue,
    ) Http {
        return .{
            .allocator = allocator,
            .io = rt.io(),
            .rt = rt,
            .queue = queue,
            .servers = std.AutoHashMap(u64, *Server).init(allocator),
            .conns = std.AutoHashMap(u64, *Conn).init(allocator),
        };
    }

    fn takeId(self: *Http) u64 {
        while (true) {
            const id = self.next_id.fetchAdd(1, .monotonic);
            if (id != 0) return id;
        }
    }

    /// Binds synchronously through `Signal`; dusty runs the server afterwards.
    pub fn listen(
        self: *Http,
        ctx: *quickjs.Context,
        host: []const u8,
        port: u16,
        backlog: u31,
        dispatch: Value,
        tls: ?TlsMaterial,
    ) !ListenResult {
        const bound_address = resolveHost(host, port) catch |err| {
            const display = if (host.len == 0) "0.0.0.0" else host;
            return .{ .failure = try listenFailure(
                self.allocator,
                "getaddrinfo",
                listenCode(err),
                display,
            ) };
        };

        const srv = try self.allocator.create(Server);
        errdefer self.allocator.destroy(srv);

        const owned_host = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(owned_host);

        const owned_cert: []u8 = if (tls) |material|
            try self.allocator.dupe(u8, material.cert)
        else
            try self.allocator.alloc(u8, 0);
        errdefer self.allocator.free(owned_cert);

        const owned_key: []u8 = if (tls) |material|
            try self.allocator.dupe(u8, material.key)
        else
            try self.allocator.alloc(u8, 0);
        errdefer self.allocator.free(owned_key);

        const owned_ca: []u8 = if (tls) |material|
            try self.allocator.dupe(u8, material.ca)
        else
            try self.allocator.alloc(u8, 0);
        errdefer self.allocator.free(owned_ca);

        srv.* = .{
            .id = self.takeId(),
            .owner = self,
            .dispatch = dispatch.dup(ctx),
            .host = owned_host,
            .tls_cert = owned_cert,
            .tls_key = owned_key,
            .tls_ca = owned_ca,
        };
        errdefer srv.dispatch.deinit(ctx);

        srv.listeners[0] = .{
            .address = .{ .ip = bound_address },
            .kernel_backlog = backlog,
            .acceptors = 1,
            .tls = if (tls) |material| dusty.ServerConfig.Tls{
                .certificate = .{ .bytes = .{
                    .cert = srv.tls_cert,
                    .key = srv.tls_key,
                } },
                .client_auth = if (material.request_cert)
                    .{
                        .ca = if (srv.tls_ca.len > 0)
                            .{ .bytes = srv.tls_ca }
                        else
                            .none,
                        .mode = if (material.reject_unauthorized) .require else .request,
                    }
                else
                    null,
            } else null,
        };
        srv.server = dusty.Server(Server).init(
            self.allocator,
            self.io,
            .{ .listeners = srv.listeners[0..] },
            srv,
        );
        srv.server.router.any("/", handleRequest);
        srv.server.router.any("/*path", handleRequest);

        self.servers.put(srv.id, srv) catch |err| {
            srv.server.deinit();
            return err;
        };
        errdefer _ = self.servers.remove(srv.id);

        var signal: Signal = .{};
        defer signal.deinit();

        srv.run_handle = self.rt.spawn(runServer, .{ srv, &signal }) catch |err| {
            srv.server.deinit();
            return err;
        };
        srv.ready_handle = self.rt.spawn(awaitReady, .{ srv, &signal }) catch |err| {
            if (srv.run_handle) |*handle| handle.cancel();
            srv.server.deinit();
            return err;
        };

        signal.wait();

        if (srv.listen_failed) {
            if (srv.ready_handle) |*handle| handle.cancel();
            srv.ready_handle = null;
            if (srv.run_handle) |*handle| handle.cancel();
            srv.run_handle = null;

            _ = self.servers.remove(srv.id);
            const failure = srv.failure orelse Failure{
                .code = "EIO",
                .errno = errnoFor("EIO"),
                .message = try self.allocator.dupe(u8, "listen EIO"),
                .syscall = try self.allocator.dupe(u8, "listen"),
            };
            srv.failure = null;
            srv.server.deinit();
            srv.dispatch.deinit(ctx);
            self.allocator.free(srv.host);
            self.allocator.free(srv.tls_cert);
            self.allocator.free(srv.tls_key);
            self.allocator.free(srv.tls_ca);
            self.allocator.destroy(srv);
            return .{ .failure = failure };
        }

        if (srv.ready_handle) |*handle| handle.join();
        srv.ready_handle = null;

        return .{ .ok = .{
            .id = srv.id,
            .address = srv.address_text,
            .family = srv.family,
            .port = srv.port,
        } };
    }

    /// Takes ownership of `reason`/`headers`/`body` in every case.
    pub fn respond(
        self: *Http,
        conn_id: u64,
        status: u16,
        reason: ?[]u8,
        headers: []HeaderPair,
        body: []u8,
        keep_alive: bool,
    ) bool {
        const conn = self.acquireConn(conn_id) orelse {
            freeResponse(self.allocator, reason, headers, body);
            return false;
        };
        defer self.releaseConn(conn);

        const slot = &conn.slot;
        slot.mutex.lockUncancelable();
        if (slot.ready or slot.closed or slot.streaming or conn.closed.load(.acquire)) {
            slot.mutex.unlock();
            freeResponse(self.allocator, reason, headers, body);
            return false;
        }

        slot.status = status;
        slot.reason = reason;
        slot.headers = headers;
        slot.body = body;
        slot.keep_alive = keep_alive;
        slot.ready = true;
        slot.mutex.unlock();
        slot.cond.signal();
        return true;
    }

    /// Commits the headers and turns the slot into a streaming body. Takes
    /// ownership of `reason`/`headers` in every case.
    pub fn streamStart(
        self: *Http,
        conn_id: u64,
        status: u16,
        reason: ?[]u8,
        headers: []HeaderPair,
        keep_alive: bool,
    ) bool {
        const conn = self.acquireConn(conn_id) orelse {
            freeStart(self.allocator, reason, headers);
            return false;
        };
        defer self.releaseConn(conn);

        const slot = &conn.slot;
        slot.mutex.lockUncancelable();
        if (slot.ready or slot.closed or slot.streaming or conn.closed.load(.acquire)) {
            slot.mutex.unlock();
            freeStart(self.allocator, reason, headers);
            return false;
        }

        slot.status = status;
        slot.reason = reason;
        slot.headers = headers;
        slot.keep_alive = keep_alive;
        slot.streaming = true;
        slot.ready = true;
        slot.mutex.unlock();
        slot.cond.signal();
        return true;
    }

    /// Queues a copy of `chunk`; false means the pending bytes crossed the
    /// high-water mark. The handler raises `drain` once it catches up.
    pub fn streamWrite(self: *Http, conn_id: u64, chunk: []const u8) bool {
        const conn = self.acquireConn(conn_id) orelse return false;
        defer self.releaseConn(conn);

        const slot = &conn.slot;
        slot.mutex.lockUncancelable();
        if (!slot.streaming or slot.stream_ended or slot.closed or conn.closed.load(.acquire)) {
            slot.mutex.unlock();
            return false;
        }

        const copy = self.allocator.dupe(u8, chunk) catch {
            slot.mutex.unlock();
            return false;
        };
        slot.chunks.append(self.allocator, copy) catch {
            slot.mutex.unlock();
            self.allocator.free(copy);
            return false;
        };
        slot.queued_bytes += chunk.len;
        const writable = slot.queued_bytes < high_water;
        if (!writable) slot.drain_pending = true;
        slot.mutex.unlock();
        slot.cond.signal();
        return writable;
    }

    /// Marks the end of the stream; the handler frames the terminator.
    pub fn streamEnd(self: *Http, conn_id: u64) bool {
        const conn = self.acquireConn(conn_id) orelse return false;
        defer self.releaseConn(conn);

        const slot = &conn.slot;
        slot.mutex.lockUncancelable();
        if (!slot.streaming or slot.stream_ended or slot.closed or conn.closed.load(.acquire)) {
            slot.mutex.unlock();
            return false;
        }
        slot.stream_ended = true;
        slot.mutex.unlock();
        slot.cond.signal();
        return true;
    }

    /// Aborts the stream and fails the handler so the connection closes.
    pub fn streamAbort(self: *Http, conn_id: u64) bool {
        const conn = self.acquireConn(conn_id) orelse return false;
        defer self.releaseConn(conn);

        const slot = &conn.slot;
        slot.mutex.lockUncancelable();
        if (slot.closed) {
            slot.mutex.unlock();
            return false;
        }
        slot.stream_ended = true;
        slot.closed = true;
        conn.closed.store(true, .release);
        slot.mutex.unlock();
        slot.cond.broadcast();
        return true;
    }

    fn acquireConn(self: *Http, id: u64) ?*Conn {
        self.map_mutex.lock();
        defer self.map_mutex.unlock();
        const conn = self.conns.get(id) orelse return null;
        _ = conn.refs.fetchAdd(1, .monotonic);
        return conn;
    }

    fn releaseConn(self: *Http, conn: *Conn) void {
        if (conn.refs.fetchSub(1, .acq_rel) == 1) self.freeConn(conn);
    }

    fn freeConn(self: *Http, conn: *Conn) void {
        conn.slot.freeBuffers(self.allocator);
        self.allocator.free(conn.remote_address);
        self.allocator.free(conn.local_address);
        self.allocator.destroy(conn);
    }

    fn removeConn(self: *Http, conn: *Conn) void {
        self.map_mutex.lock();
        _ = self.conns.remove(conn.id);
        self.map_mutex.unlock();
        self.releaseConn(conn);
    }

    pub fn closeServer(self: *Http, id: u64) bool {
        const srv = self.servers.get(id) orelse return false;
        if (srv.closed.swap(true, .acq_rel)) return true;

        // Dusty stops accepting and drains in-flight requests when `run` is
        // canceled. Cancel from a zio task: `cancel` waits for the drain, and
        // the drain waits for JS handlers, so doing it here would deadlock.
        srv.stop_handle = self.rt.spawn(stopServer, .{srv}) catch {
            // No task for the deferred cancel: fail open handlers so the
            // synchronous cancel below cannot wait forever on them.
            self.closeConns(id);
            if (srv.run_handle) |*handle| {
                handle.cancel();
                srv.run_handle = null;
            }
            return true;
        };
        return true;
    }

    /// Marks every request slot of one server (or all) closed and wakes the
    /// handlers. The map mutex keeps records from disappearing underneath us.
    fn closeConns(self: *Http, server_id: ?u64) void {
        self.map_mutex.lock();
        defer self.map_mutex.unlock();

        var iterator = self.conns.valueIterator();
        while (iterator.next()) |slot| {
            const conn = slot.*;
            if (server_id) |wanted| {
                if (conn.server.id != wanted) continue;
            }
            conn.closed.store(true, .release);
            conn.slot.mutex.lockUncancelable();
            conn.slot.closed = true;
            conn.slot.cond.broadcast();
            conn.slot.mutex.unlock();
        }
    }

    pub fn address(self: *Http, id: u64) ?AddressInfo {
        const srv = self.servers.get(id) orelse return null;
        return .{ .address = srv.address_text, .family = srv.family, .port = srv.port };
    }

    pub fn setRef(self: *Http, id: u64, ref: bool, loop: *@import("event_loop.zig").EventLoop) bool {
        const srv = self.servers.get(id) orelse return false;
        if (srv.refs == ref) return true;
        srv.refs = ref;
        if (ref) loop.ref() else loop.unref();
        return true;
    }

    /// Stops every server, wakes blocked handlers, then frees records. Runs on
    /// the JS task before `queue.shutdown`.
    pub fn deinit(self: *Http, ctx: *quickjs.Context) void {
        var server_it = self.servers.valueIterator();
        while (server_it.next()) |slot| slot.*.closed.store(true, .release);

        self.closeConns(null);

        server_it = self.servers.valueIterator();
        while (server_it.next()) |slot| {
            const srv = slot.*;
            if (srv.ready_handle) |*handle| handle.cancel();
            srv.ready_handle = null;

            var run: ?zio.JoinHandle(void) = null;
            var stop: ?zio.JoinHandle(void) = null;
            self.map_mutex.lock();
            run = srv.run_handle;
            srv.run_handle = null;
            stop = srv.stop_handle;
            srv.stop_handle = null;
            self.map_mutex.unlock();

            if (run) |handle| {
                var pending = handle;
                pending.cancel();
            }
            if (stop) |handle| {
                var pending = handle;
                pending.join();
            }
        }

        // Handlers have removed their own records by now; free leftovers.
        var leftovers: std.ArrayList(*Conn) = .empty;
        defer leftovers.deinit(self.allocator);
        self.map_mutex.lock();
        var conn_it = self.conns.valueIterator();
        while (conn_it.next()) |slot| {
            leftovers.append(self.allocator, slot.*) catch continue;
        }
        self.conns.clearRetainingCapacity();
        self.map_mutex.unlock();

        for (leftovers.items) |conn| {
            conn.closed.store(true, .release);
            conn.slot.closed = true;
            conn.slot.freeBuffers(self.allocator);
            self.allocator.free(conn.remote_address);
            self.allocator.free(conn.local_address);
            self.allocator.destroy(conn);
        }

        server_it = self.servers.valueIterator();
        while (server_it.next()) |slot| {
            const srv = slot.*;
            if (srv.failure) |*failure| failure.deinit(self.allocator);
            srv.server.deinit();
            self.allocator.free(srv.address_text);
            self.allocator.free(srv.host);
            self.allocator.free(srv.tls_cert);
            self.allocator.free(srv.tls_key);
            self.allocator.free(srv.tls_ca);
            srv.dispatch.deinit(ctx);
            self.allocator.destroy(srv);
        }
        self.servers.deinit();
        self.conns.deinit();
        self.map_mutex.deinit();
    }

    fn send(self: *Http, server: *Server, kind: Kind) bool {
        const job = self.allocator.create(HttpJob) catch {
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
            .server = server,
            .kind = kind,
        };

        self.queue.submit(&job.link) catch {
            freeKind(self.allocator, job.kind);
            self.allocator.destroy(job);
            return false;
        };
        self.queue.complete(&job.link);
        return true;
    }
};

fn freeResponse(
    allocator: std.mem.Allocator,
    reason: ?[]u8,
    headers: []HeaderPair,
    body: []u8,
) void {
    if (reason) |text| allocator.free(text);
    freeHeaders(allocator, headers);
    allocator.free(body);
}

fn freeStart(
    allocator: std.mem.Allocator,
    reason: ?[]u8,
    headers: []HeaderPair,
) void {
    if (reason) |text| allocator.free(text);
    freeHeaders(allocator, headers);
}

fn clearException(ctx: *quickjs.Context) void {
    const exception = ctx.getException();
    exception.deinit(ctx);
}

fn setField(ctx: *quickjs.Context, object: Value, name: [*:0]const u8, value: Value) bool {
    object.setPropertyStr(ctx, name, value) catch return false;
    return true;
}

fn buildFailure(ctx: *quickjs.Context, failure: Failure) Value {
    const object = Value.initObject(ctx);
    if (object.isException()) return object;

    var ok = setField(ctx, object, "code", Value.initString(ctx, failure.code));
    if (ok) ok = setField(ctx, object, "message", Value.initStringLen(ctx, failure.message));
    if (ok) ok = setField(ctx, object, "errno", Value.initInt32(failure.errno));
    if (ok) ok = setField(ctx, object, "syscall", Value.initStringLen(ctx, failure.syscall));
    if (!ok) {
        object.deinit(ctx);
        return .undefined;
    }
    return object;
}

fn buildRequestPayload(ctx: *quickjs.Context, payload: *const RequestPayload) Value {
    const object = Value.initObject(ctx);
    if (object.isException()) return object;

    var ok = true;
    if (ok) ok = setField(ctx, object, "serverId", Value.initFloat64(@floatFromInt(payload.server_id)));
    if (ok) ok = setField(ctx, object, "connId", Value.initFloat64(@floatFromInt(payload.conn_id)));
    if (ok) ok = setField(ctx, object, "method", Value.initStringLen(ctx, payload.method));
    if (ok) ok = setField(ctx, object, "url", Value.initStringLen(ctx, payload.url));
    if (ok) ok = setField(ctx, object, "httpVersion", Value.initStringLen(ctx, payload.version));

    if (ok) {
        const headers = Value.initArray(ctx);
        if (headers.isException()) {
            ok = false;
        } else {
            for (payload.headers, 0..) |pair, index| {
                const name_value = Value.initStringLen(ctx, pair.name);
                headers.setPropertyUint32(ctx, @intCast(index * 2), name_value) catch {
                    ok = false;
                    break;
                };
                const value_value = Value.initStringLen(ctx, pair.value);
                headers.setPropertyUint32(ctx, @intCast(index * 2 + 1), value_value) catch {
                    ok = false;
                    break;
                };
            }
            if (ok) {
                ok = setField(ctx, object, "headers", headers);
            } else {
                headers.deinit(ctx);
            }
        }
    }

    if (ok) {
        const body = Value.initUint8ArrayCopy(ctx, payload.body);
        if (body.isException()) {
            clearException(ctx);
            ok = false;
        } else {
            ok = setField(ctx, object, "body", body);
        }
    }

    if (ok) ok = setField(ctx, object, "remoteAddress", Value.initStringLen(ctx, payload.remote_address));
    if (ok) ok = setField(ctx, object, "remotePort", Value.initInt32(payload.remote_port));
    if (ok) ok = setField(ctx, object, "localAddress", Value.initStringLen(ctx, payload.local_address));
    if (ok) ok = setField(ctx, object, "localPort", Value.initInt32(payload.local_port));
    if (ok) ok = setField(ctx, object, "keepAlive", Value.initBool(payload.keep_alive));

    if (!ok) {
        object.deinit(ctx);
        return .undefined;
    }
    return object;
}

/// Invokes the JS trampoline; it owns the payload from here.
fn callDispatch(
    ctx: *quickjs.Context,
    server: *Server,
    id: u64,
    event: [*:0]const u8,
    payload: Value,
) void {
    const id_value = Value.initFloat64(@floatFromInt(id));
    defer id_value.deinit(ctx);
    const event_value = Value.initString(ctx, event);
    defer event_value.deinit(ctx);
    defer payload.deinit(ctx);

    const result = server.dispatch.call(
        ctx,
        .undefined,
        &.{ id_value, event_value, payload },
    );
    defer result.deinit(ctx);
    // Listener errors are rethrown asynchronously by the JS wrapper; never let
    // an exception escape the native frame.
    if (result.isException()) clearException(ctx);
}

fn settleJob(ctx: *quickjs.Context, link: *jobs.Job) void {
    const job: *HttpJob = @ptrCast(@alignCast(link.context));
    const owner = job.owner;
    defer owner.allocator.destroy(job);

    switch (job.kind) {
        .request => |payload| {
            defer {
                var copy = payload;
                copy.deinit(owner.allocator);
            }
            var object = buildRequestPayload(ctx, &payload);
            if (object.isException()) {
                clearException(ctx);
                return;
            }
            if (object.isUndefined()) return;
            callDispatch(ctx, job.server, payload.conn_id, "request", object);
        },
        .conn_close => |conn_id| {
            callDispatch(ctx, job.server, conn_id, "close", Value.null);
        },
        .drain => |conn_id| {
            callDispatch(ctx, job.server, conn_id, "drain", Value.null);
        },
        .server_close => |server_id| {
            if (job.server.stop_handle) |*handle| handle.join();
            job.server.stop_handle = null;
            owner.map_mutex.lock();
            const run = job.server.run_handle;
            job.server.run_handle = null;
            owner.map_mutex.unlock();
            if (run) |handle| {
                var pending = handle;
                pending.join();
            }
            if (ctx.getOpaque(Host)) |host| {
                if (job.server.refs) host.loop.unref();
            }
            callDispatch(ctx, job.server, server_id, "close", Value.null);

            const srv = job.server;
            _ = owner.servers.remove(srv.id);
            if (srv.failure) |*failure| failure.deinit(owner.allocator);
            srv.server.deinit();
            owner.allocator.free(srv.address_text);
            owner.allocator.free(srv.host);
            owner.allocator.free(srv.tls_cert);
            owner.allocator.free(srv.tls_key);
            owner.allocator.free(srv.tls_ca);
            srv.dispatch.deinit(ctx);
            owner.allocator.destroy(srv);
        },
        .server_error => |entry| {
            var failure = entry.failure;
            defer failure.deinit(owner.allocator);
            const object = buildFailure(ctx, failure);
            if (object.isException()) {
                clearException(ctx);
                return;
            }
            callDispatch(ctx, job.server, entry.server_id, "error", object);
        },
    }
}

fn abortJob(_: *quickjs.Context, link: *jobs.Job) void {
    const job: *HttpJob = @ptrCast(@alignCast(link.context));
    const owner = job.owner;
    freeKind(owner.allocator, job.kind);
    owner.allocator.destroy(job);
}

fn resolveHost(host: []const u8, port: u16) !std.Io.net.IpAddress {
    if (host.len == 0) return std.Io.net.IpAddress.parse("0.0.0.0", port);
    if (std.ascii.eqlIgnoreCase(host, "localhost")) {
        return std.Io.net.IpAddress.parse("127.0.0.1", port);
    }
    if (std.Io.net.IpAddress.parse(host, port)) |address| return address else |_| {}

    var storage: [8]zio.net.HostName.LookupResult = undefined;
    const name = try zio.net.HostName.init(host);
    const count = try name.lookup(&storage, .{ .port = port });
    for (storage[0..count]) |entry| switch (entry) {
        .address => |address| return fromZioAddress(address),
        .canonical_name => {},
    };
    return error.UnknownHostName;
}

fn fromZioAddress(address: zio.net.IpAddress) std.Io.net.IpAddress {
    return switch (address.getFamily()) {
        .ipv4 => .{ .ip4 = .{
            .bytes = @bitCast(address.in.addr),
            .port = address.in.port,
        } },
        .ipv6 => .{ .ip6 = .{
            .bytes = address.in6.addr,
            .port = address.in6.port,
            .flow = address.in6.flowinfo,
        } },
    };
}

/// Formats an address without its port, matching Node's `address()`.
fn formatAddress(allocator: std.mem.Allocator, address: std.Io.net.IpAddress) ![]u8 {
    switch (address) {
        .ip4 => |ip| {
            return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
                ip.bytes[0], ip.bytes[1], ip.bytes[2], ip.bytes[3],
            });
        },
        .ip6 => {
            var copy = address;
            copy.ip6.port = 0;
            var writer: std.Io.Writer.Allocating = .init(allocator);
            defer writer.deinit();
            try copy.format(&writer.writer);

            var text = writer.written();
            if (std.mem.lastIndexOfScalar(u8, text, ':')) |colon| text = text[0..colon];
            if (text.len >= 2 and text[0] == '[' and text[text.len - 1] == ']') {
                text = text[1 .. text.len - 1];
            }
            return allocator.dupe(u8, text);
        },
    }
}

fn formatAddressPort(allocator: std.mem.Allocator, address: std.Io.net.IpAddress) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try address.format(&writer.writer);
    return allocator.dupe(u8, writer.written());
}

/// Runs on a zio task so the JS task stays free to answer the requests dusty
/// drains before `cancel` returns.
fn stopServer(srv: *Server) void {
    var run: ?zio.JoinHandle(void) = null;
    srv.owner.map_mutex.lock();
    if (srv.run_handle) |handle| {
        run = handle;
        srv.run_handle = null;
    }
    srv.owner.map_mutex.unlock();

    if (run) |handle| {
        var pending = handle;
        pending.cancel();
    }
}

fn runServer(srv: *Server, signal: *Signal) void {
    srv.server.run() catch |err| {
        if (!srv.ready.load(.acquire)) {
            const detail = if (srv.host.len == 0) "0.0.0.0" else srv.host;
            srv.failure = listenFailure(srv.owner.allocator, "listen", listenCode(err), detail) catch null;
            srv.listen_failed = true;
            signal.notify();
            return;
        }
        if (err != error.Canceled and !srv.closed.load(.acquire)) {
            const detail = if (srv.host.len == 0) "0.0.0.0" else srv.host;
            const failure = listenFailure(srv.owner.allocator, "listen", listenCode(err), detail) catch null;
            if (failure) |value| {
                _ = srv.owner.send(srv, .{ .server_error = .{ .server_id = srv.id, .failure = value } });
            }
        }
    };

    if (srv.ready.load(.acquire) and !srv.close_sent.swap(true, .acq_rel)) {
        _ = srv.owner.send(srv, .{ .server_close = srv.id });
    }
}

fn awaitReady(srv: *Server, signal: *Signal) void {
    srv.server.ready.wait(srv.owner.io) catch return;
    if (srv.listen_failed) {
        signal.notify();
        return;
    }

    const bound = switch (srv.server.addresses[0]) {
        .ip => |address| address,
        .unix => {
            srv.ready.store(true, .release);
            signal.notify();
            return;
        },
    };
    const port = bound.getPort();
    const family: []const u8 = switch (bound) {
        .ip4 => "IPv4",
        .ip6 => "IPv6",
    };
    srv.port = port;
    srv.family = family;
    srv.address_text = formatAddress(srv.owner.allocator, bound) catch &.{};
    srv.ready.store(true, .release);
    signal.notify();
}

fn isReservedHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "content-length") or
        isForbiddenHeader(name);
}

/// Framing headers dusty owns for a streamed body; `Content-Length` is the
/// exception, since it selects the stream's framing.
fn isForbiddenHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding");
}

fn readHeaders(allocator: std.mem.Allocator, req: *dusty.Request) ![]HeaderPair {
    var list: std.ArrayList(HeaderPair) = .empty;
    errdefer {
        for (list.items) |pair| {
            allocator.free(pair.name);
            allocator.free(pair.value);
        }
        list.deinit(allocator);
    }

    var iterator = req.headers.iterator();
    while (iterator.next()) |entry| {
        const name = try allocator.dupe(u8, entry.key);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, entry.value);
        errdefer allocator.free(value);
        try list.append(allocator, .{ .name = name, .value = value });
    }
    return list.toOwnedSlice(allocator);
}

fn connectEntry(
    owner: *Http,
    srv: *Server,
    req: *dusty.Request,
) !struct { conn: *Conn, payload: RequestPayload } {
    const allocator = owner.allocator;

    const remote = formatAddress(allocator, req.remote_address) catch try allocator.dupe(u8, "0.0.0.0");
    errdefer allocator.free(remote);

    const local = switch (req.listener.address) {
        .ip => |address| formatAddress(allocator, address) catch try allocator.dupe(u8, "0.0.0.0"),
        .unix => try allocator.dupe(u8, "127.0.0.1"),
    };
    errdefer allocator.free(local);

    const body = req.body() catch |err| switch (err) {
        error.BodyTooBig => {
            allocator.free(remote);
            allocator.free(local);
            return error.BodyTooBig;
        },
        else => return err,
    };
    const body_copy = try allocator.dupe(u8, body orelse "");
    errdefer allocator.free(body_copy);

    const url = try allocator.dupe(u8, req.url);
    errdefer allocator.free(url);

    const headers = try readHeaders(allocator, req);
    errdefer freeHeaders(allocator, headers);

    const conn = try allocator.create(Conn);
    errdefer allocator.destroy(conn);
    conn.* = .{
        .id = owner.takeId(),
        .owner = owner,
        .server = srv,
        .remote_address = remote,
        .remote_port = req.remote_address.getPort(),
        .local_address = local,
        .local_port = switch (req.listener.address) {
            .ip => |address| address.getPort(),
            .unix => 0,
        },
    };

    // The request payload owns its own copies: the connection record has the
    // same text for the JS response path, and both are freed independently.
    const payload_remote = try allocator.dupe(u8, conn.remote_address);
    errdefer allocator.free(payload_remote);
    const payload_local = try allocator.dupe(u8, conn.local_address);
    errdefer allocator.free(payload_local);

    return .{
        .conn = conn,
        .payload = .{
            .server_id = srv.id,
            .conn_id = conn.id,
            .method = req.method.name(),
            .url = url,
            .version = if (req.version_major == 1 and req.version_minor == 0) "1.0" else "1.1",
            .headers = headers,
            .body = body_copy,
            .remote_address = payload_remote,
            .remote_port = conn.remote_port,
            .local_address = payload_local,
            .local_port = conn.local_port,
            .keep_alive = if (req.headers.get("connection")) |value|
                !std.ascii.eqlIgnoreCase(value, "close")
            else
                true,
        },
    };
}

fn handleRequest(srv: *Server, req: *dusty.Request, res: *dusty.Response) anyerror!void {
    const owner = srv.owner;
    const allocator = owner.allocator;

    const entry = connectEntry(owner, srv, req) catch |err| switch (err) {
        error.BodyTooBig => {
            res.status = .payload_too_large;
            res.body = "Payload Too Large";
            return;
        },
        else => return err,
    };
    const conn = entry.conn;
    var payload = entry.payload;
    var committed = false;
    defer if (!committed) payload.deinit(allocator);

    owner.map_mutex.lock();
    const put_result = owner.conns.put(conn.id, conn);
    owner.map_mutex.unlock();
    if (put_result) |_| {} else |_| {
        allocator.free(conn.remote_address);
        allocator.free(conn.local_address);
        allocator.destroy(conn);
        return error.OutOfMemory;
    }

    defer {
        // Tell JS the request is over even when the response never arrives, so
        // its `pending` entry cannot leak.
        _ = owner.send(srv, .{ .conn_close = conn.id });
        owner.removeConn(conn);
    }

    if (!owner.send(srv, .{ .request = payload })) {
        res.status = .internal_server_error;
        res.body = "Internal Server Error";
        return;
    }
    committed = true;

    const slot = &conn.slot;
    slot.mutex.lockUncancelable();
    while (!slot.ready and !slot.closed) slot.cond.waitUncancelable(&slot.mutex);
    if (!slot.ready) {
        slot.mutex.unlock();
        res.status = .service_unavailable;
        res.body = "Service Unavailable";
        return;
    }

    const status = slot.status;
    const reason = slot.reason;
    const headers = slot.headers;
    const body = slot.body;
    const keep_alive = slot.keep_alive;
    const streaming = slot.streaming;
    const aborted = slot.closed;
    slot.reason = null;
    slot.headers = &.{};
    slot.body = &.{};
    slot.ready = false;
    slot.mutex.unlock();
    defer freeResponse(allocator, reason, headers, body);

    res.status = dusty.Status.fromCode(status) catch .ok;
    res.status_code = status;
    if (reason) |text| res.status_text = try req.arena.dupe(u8, text);
    res.keepalive = keep_alive;

    for (headers) |pair| {
        // `Content-Length` selects the framing of a streamed body, so only
        // the buffered path lets dusty compute it.
        if (!streaming and isReservedHeader(pair.name)) continue;
        if (streaming and isForbiddenHeader(pair.name)) continue;
        const name = try req.arena.dupe(u8, pair.name);
        const value = try req.arena.dupe(u8, pair.value);
        res.header(name, value) catch {};
    }

    if (aborted) {
        // Aborted before anything went out: close without a response.
        res.written = true;
        res.keepalive = false;
        return;
    }

    if (!streaming) {
        const body_copy = try req.arena.dupe(u8, body);
        res.body = body_copy;
        return;
    }

    // `stream` sends the headers immediately, so everything above has to be
    // settled before it is called. Each queued chunk becomes one HTTP chunk;
    // `end` frames the terminator.
    var buf: [16 * 1024]u8 = undefined;
    var writer = res.stream(&buf) catch |err| return err;

    while (true) {
        slot.mutex.lockUncancelable();
        while (slot.chunks.items.len == 0 and !slot.stream_ended and !slot.closed) {
            slot.cond.waitUncancelable(&slot.mutex);
        }
        const closed = slot.closed;
        const ended = slot.stream_ended;
        var chunks = slot.chunks;
        slot.chunks = .empty;
        const drain = slot.drain_pending and !closed;
        if (drain) slot.drain_pending = false;
        slot.queued_bytes = 0;
        slot.mutex.unlock();

        var failed = false;
        for (chunks.items) |chunk| {
            defer allocator.free(chunk);
            if (closed or failed) continue;
            writer.interface.writeAll(chunk) catch {
                failed = true;
            };
        }
        if (!closed and !failed) writer.interface.flush() catch {
            failed = true;
        };
        chunks.deinit(allocator);

        if (drain) _ = owner.send(srv, .{ .drain = conn.id });
        if (closed) {
            // Aborted: stop without framing the body so the peer sees a
            // truncated stream and the connection is not reused.
            res.written = true;
            res.keepalive = false;
            break;
        }
        if (failed) {
            // The connection is already broken; do not attempt a terminator.
            res.written = true;
            res.keepalive = false;
            break;
        }
        if (ended) {
            writer.end() catch {
                res.keepalive = false;
            };
            break;
        }
    }
}
