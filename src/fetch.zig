// `fetch` coordinator over `dusty.Client`.
//
// The request runs entirely in a zio task; the JS task only builds the request
// payload and settles promises. QuickJS values are never touched off the JS
// task, so a streamed body crosses the boundary as owned byte slices.
//
// A buffered request reports once. A streaming request settles its head
// promise, then hands the body over one chunk per `ack(id)`, so backpressure
// is simply JS not asking for the next chunk.

const std = @import("std");
const builtin = @import("builtin");
const quickjs = @import("quickjs");
const zio = @import("zio");
const dusty = @import("dusty");
const jobs = @import("jobs.zig");

/// Node's `fetch` refuses to allocate more than this for a single body.
pub const max_body_bytes = 10 * 1024 * 1024;

/// An owned response header, marshalled as a flat `[name, value, ...]` array.
pub const HeaderPair = struct {
    name: []u8,
    value: []u8,
};

/// A fully buffered response; every slice is owned by the job.
pub const Outcome = struct {
    status: u16,
    status_text: []u8,
    headers: []HeaderPair,
    body: []u8,
    url: []u8,
};

/// Why a request failed. The message is built from `err` on the JS task so a
/// failing allocation never hides the original failure.
pub const Failure = struct {
    err: anyerror,
    code: [:0]const u8,
    errno: i32 = 0,
};

/// Per-request TLS material, owned by the job until it reaches a cached
/// client. Empty means the shared default client.
pub const TlsRequest = struct {
    ca: ?[]u8 = null,
    cert: ?[]u8 = null,
    key: ?[]u8 = null,
    reject_unauthorized: bool = true,

    pub fn isEmpty(self: *const TlsRequest) bool {
        return self.ca == null and self.cert == null and self.key == null and self.reject_unauthorized;
    }

    pub fn deinit(self: *TlsRequest, allocator: std.mem.Allocator) void {
        if (self.ca) |bytes| allocator.free(bytes);
        if (self.cert) |bytes| allocator.free(bytes);
        if (self.key) |bytes| allocator.free(bytes);
        self.* = .{};
    }
};

/// How a completion-queue entry settles. Streaming requests use their own
/// per-event node, the buffered path uses `Job.link`.
const Event = enum { response, head, chunk, end, failure };

/// One queued streaming event. `jobs.Job` holds a single link, so each event
/// owns a node: the head and a later failure can be in the queue together.
const StreamEvent = struct {
    link: jobs.Job = undefined,
    job: *Job,
    allocator: std.mem.Allocator,
    kind: Event,
    chunk: ?[]u8 = null,
};

pub const Job = struct {
    allocator: std.mem.Allocator = undefined,
    /// Identifies this job for an in-flight abort from the JS task.
    id: u64 = 0,
    owner: *Fetch = undefined,
    /// Owned copies of everything the zio task touches.
    url: []u8 = &.{},
    method: dusty.Method = .get,
    /// Owned name/value strings; `header_table` points into them.
    header_pairs: []HeaderPair = &.{},
    header_table: dusty.Headers = .{},
    body: []u8 = &.{},
    has_body: bool = false,
    max_redirects: u8 = 5,
    /// `null` keeps dusty's default; `0` disables the timeout.
    timeout_ms: ?u32 = null,
    decompress: bool = true,
    /// Optional TLS material; released with the rest of the request payload.
    tls: TlsRequest = .{},
    /// Selected in `submit`: the shared client or a cached TLS one.
    client: ?*dusty.Client = null,
    /// Streaming is on exactly when `on_chunk` is a function.
    stream: bool = false,
    /// Owned QuickJS callbacks, released on the JS task.
    on_chunk: quickjs.Value = .undefined,
    on_end: quickjs.Value = .undefined,
    on_error: quickjs.Value = .undefined,
    /// The head promise is settled; failures now go to `on_error` and the job
    /// lives until the body ends or aborts.
    head_settled: bool = false,
    /// A terminal event was queued; the job dies with its last event.
    terminated: bool = false,
    /// Stream events still in the completion queue; written by the zio task,
    /// read on the JS task.
    pending_events: std.atomic.Value(usize) = .init(0),
    /// One `ack(id)` from JS grants one body read. The mutex is needed because
    /// the JS task is a foreign thread to zio.
    ack_mutex: zio.Mutex = .init,
    ack_cond: zio.Condition = .init,
    ack_granted: u64 = 0,
    ack_taken: u64 = 0,
    /// Buffered completions report through `Job.link`; streaming events carry
    /// their own node and set `event` there.
    event: Event = .response,
    /// Owned by the zio task; taken out before a cancel or join so a stale
    /// copy is never released twice.
    handle: ?zio.JoinHandle(void) = null,
    resolve: quickjs.Value = .undefined,
    reject: quickjs.Value = .undefined,
    outcome: ?Outcome = null,
    failure: ?Failure = null,
    /// Completion-queue node; `context` points back at this job.
    link: jobs.Job = undefined,

    /// Releases the request payload plus any queued result, then the job.
    pub fn free(self: *Job) void {
        if (self.handle) |handle| {
            self.handle = null;
            var done = handle;
            done.join();
        }
        self.freeRequest();
        if (self.outcome) |*outcome| {
            self.allocator.free(outcome.status_text);
            self.allocator.free(outcome.url);
            self.allocator.free(outcome.body);
            freeHeaderPairs(self.allocator, outcome.headers);
            self.allocator.free(outcome.headers);
        }
        self.allocator.destroy(self);
    }

    /// Releases only the request payload; used when a job never starts.
    pub fn freeRequest(self: *Job) void {
        if (self.url.len > 0) self.allocator.free(self.url);
        for (self.header_pairs) |pair| {
            self.allocator.free(pair.name);
            self.allocator.free(pair.value);
        }
        if (self.header_pairs.len > 0) self.allocator.free(self.header_pairs);
        self.header_table.deinit(self.allocator);
        if (self.body.len > 0) self.allocator.free(self.body);
        self.tls.deinit(self.allocator);
    }

    /// Releases the QuickJS values the job owns. Runs on the JS task only.
    pub fn deinitValues(self: *Job, ctx: *quickjs.Context) void {
        self.resolve.deinit(ctx);
        self.reject.deinit(ctx);
        self.on_chunk.deinit(ctx);
        self.on_end.deinit(ctx);
        self.on_error.deinit(ctx);
        self.resolve = .undefined;
        self.reject = .undefined;
        self.on_chunk = .undefined;
        self.on_end = .undefined;
        self.on_error = .undefined;
    }

    /// Drops one queued event; the job is released when its last event and its
    /// terminal event have both been handled.
    fn eventDone(self: *Job, ctx: *quickjs.Context) void {
        const before = self.pending_events.fetchSub(1, .acq_rel);
        if (before == 1 and self.terminated) self.destroy(ctx);
    }

    fn destroy(self: *Job, ctx: *quickjs.Context) void {
        self.deinitValues(ctx);
        self.owner.retire(self.id);
        self.free();
    }
};

fn freeHeaderPairs(allocator: std.mem.Allocator, pairs: []HeaderPair) void {
    for (pairs) |pair| {
        allocator.free(pair.name);
        allocator.free(pair.value);
    }
}

/// One cached client per distinct TLS configuration. Dusty borrows the CA and
/// client-certificate bytes for the client's life, so this entry owns them.
const TlsClient = struct {
    client: dusty.Client,
    hash: [32]u8,
    ca: ?[]u8 = null,
    cert: ?[]u8 = null,
    key: ?[]u8 = null,
    reject_unauthorized: bool = true,

    fn matches(self: *const TlsClient, tls: *const TlsRequest) bool {
        return self.reject_unauthorized == tls.reject_unauthorized and
            sameOptional(self.ca, tls.ca) and
            sameOptional(self.cert, tls.cert) and
            sameOptional(self.key, tls.key);
    }
};

fn sameOptional(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn freeTlsStrings(allocator: std.mem.Allocator, entry: *TlsClient) void {
    if (entry.ca) |bytes| allocator.free(bytes);
    if (entry.cert) |bytes| allocator.free(bytes);
    if (entry.key) |bytes| allocator.free(bytes);
    entry.ca = null;
    entry.cert = null;
    entry.key = null;
}

/// Length-prefixed so no two field layouts hash alike.
fn tlsHash(ca: ?[]const u8, cert: ?[]const u8, key: ?[]const u8, reject_unauthorized: bool) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for ([_]?[]const u8{ ca, cert, key }) |part| {
        var header: [9]u8 = @splat(0);
        if (part) |bytes| {
            header[0] = 1;
            std.mem.writeInt(u64, header[1..9], bytes.len, .little);
            hasher.update(&header);
            hasher.update(bytes);
        } else {
            hasher.update(&header);
        }
    }
    hasher.update(&[_]u8{@intFromBool(reject_unauthorized)});

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

/// Runs fetch jobs in zio tasks and reports them to the runtime's shared
/// completion queue; only the JS thread touches QuickJS values.
pub const Fetch = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    rt: *zio.Runtime,
    queue: *jobs.Queue,
    /// A single client keeps the connection pool and the TLS state warm.
    client: dusty.Client,
    /// Clients for requests with their own TLS material; dusty TLS is
    /// client-wide, so each distinct configuration needs its own pool.
    tls_clients: std.ArrayList(*TlsClient) = .empty,
    /// In-flight jobs by id; the JS task uses it for `AbortSignal`.
    active: std.AutoHashMap(u64, *Job),
    active_open: bool = true,

    pub fn init(
        allocator: std.mem.Allocator,
        rt: *zio.Runtime,
        queue: *jobs.Queue,
    ) Fetch {
        return .{
            .allocator = allocator,
            .io = rt.io(),
            .rt = rt,
            .queue = queue,
            .client = .init(allocator, rt.io(), .{ .max_response_size = max_body_bytes }),
            .tls_clients = .empty,
            .active = std.AutoHashMap(u64, *Job).init(allocator),
        };
    }

    pub fn submit(self: *Fetch, job: *Job) !void {
        job.allocator = self.allocator;
        job.owner = self;
        job.client = try self.clientFor(&job.tls);
        job.link = .{
            .context = job,
            .settle = settleJob,
            .abort = abortJob,
        };

        try self.active.ensureUnusedCapacity(1);
        try self.queue.submit(&job.link);

        const handle = self.rt.spawn(run, .{ self, job }) catch |err| {
            // The task never started, so the job must not stay pending.
            self.queue.cancel();
            return err;
        };
        job.handle = handle;
        self.active.putAssumeCapacity(job.id, job);

        self.reapFinished();
    }

    /// Cancels one in-flight request, used by an aborted `fetch` or
    /// `ClientRequest`. The caller sees `ABORT_ERR` when the task settles.
    pub fn abort(self: *Fetch, id: u64) bool {
        const job = self.active.get(id) orelse return false;
        if (job.handle) |handle| {
            job.handle = null;
            var pending = handle;
            // Waits for the task, which unblocks its ack wait and queues the
            // terminal event; that event frees the job.
            pending.cancel();
            return true;
        }
        return false;
    }

    /// Grants the streaming job one more body read. Returns false for an
    /// unknown id or a buffered request.
    pub fn ack(self: *Fetch, id: u64) bool {
        const job = self.active.get(id) orelse return false;
        if (!job.stream) return false;

        job.ack_mutex.lockUncancelable();
        job.ack_granted +%= 1;
        job.ack_mutex.unlock();
        job.ack_cond.signal();
        return true;
    }

    /// Returns the shared client, or the cached one for this TLS setup. The
    /// entry's strings are copies, so freeing the job cannot pull them out
    /// from under a live client.
    fn clientFor(self: *Fetch, tls: *const TlsRequest) !*dusty.Client {
        if (tls.isEmpty()) return &self.client;

        const hash = tlsHash(tls.ca, tls.cert, tls.key, tls.reject_unauthorized);
        for (self.tls_clients.items) |entry| {
            if (!std.mem.eql(u8, &entry.hash, &hash)) continue;
            if (entry.matches(tls)) return &entry.client;
        }

        const entry = try self.allocator.create(TlsClient);
        errdefer self.allocator.destroy(entry);
        entry.* = .{ .client = undefined, .hash = hash };
        errdefer freeTlsStrings(self.allocator, entry);
        if (tls.ca) |bytes| entry.ca = try self.allocator.dupe(u8, bytes);
        if (tls.cert) |bytes| entry.cert = try self.allocator.dupe(u8, bytes);
        if (tls.key) |bytes| entry.key = try self.allocator.dupe(u8, bytes);
        entry.reject_unauthorized = tls.reject_unauthorized;

        var config: dusty.ClientConfig = .{ .max_response_size = max_body_bytes };
        config.tls = .{
            .ca = if (!entry.reject_unauthorized)
                .none
            else if (entry.ca) |bytes|
                .{ .bytes = bytes }
            else
                .system,
            .client_certificate = if (entry.cert != null and entry.key != null)
                .{ .bytes = .{ .cert = entry.cert.?, .key = entry.key.? } }
            else
                null,
            .insecure_skip_verify = !entry.reject_unauthorized,
        };

        entry.client = .init(self.allocator, self.io, config);
        try self.tls_clients.append(self.allocator, entry);
        return &entry.client;
    }

    fn retire(self: *Fetch, id: u64) void {
        if (self.active_open) _ = self.active.remove(id);
    }

    /// Frees awaitables of finished requests instead of growing until exit.
    fn reapFinished(self: *Fetch) void {
        var iterator = self.active.valueIterator();
        while (iterator.next()) |slot| {
            const job = slot.*;
            if (job.handle) |handle| {
                if (!handle.hasResult()) continue;
                var done = handle;
                job.handle = null;
                done.join();
            }
        }
    }

    fn run(self: *Fetch, job: *Job) void {
        if (job.stream) {
            self.runStream(job);
            return;
        }

        job.outcome = self.execute(job) catch |err| {
            const info = classify(err);
            job.failure = .{ .err = err, .code = info.code, .errno = info.errno };
            job.event = .failure;
            self.queue.complete(&job.link);
            return;
        };
        job.event = .response;
        self.queue.complete(&job.link);
    }

    fn timeoutOf(job: *const Job) ?std.Io.Timeout {
        if (job.timeout_ms) |ms| {
            if (ms == 0) return .none;
            return .{ .duration = .{
                .raw = std.Io.Duration.fromMilliseconds(ms),
                .clock = .awake,
            } };
        }
        return null;
    }

    fn requestOptions(job: *const Job, stream: bool) dusty.FetchOptions {
        return .{
            .method = job.method,
            .headers = if (job.header_pairs.len == 0) null else &job.header_table,
            .body = if (job.has_body) job.body else null,
            .max_redirects = job.max_redirects,
            .timeout = timeoutOf(job),
            .decompress = job.decompress,
            .stream = stream,
        };
    }

    fn execute(self: *Fetch, job: *Job) !Outcome {
        var response = self.clientOf(job).fetch(job.url, requestOptions(job, false)) catch |err| return err;
        defer response.deinit();

        // The response's memory lives in the connection arena, so copy
        // everything before `deinit` hands the connection back to the pool.
        const status: u16 = response.statusCode();
        const status_text = try self.allocator.dupe(u8, response.statusText());
        errdefer self.allocator.free(status_text);

        const headers = try self.copyHeaders(response.headers());
        errdefer {
            freeHeaderPairs(self.allocator, headers);
            self.allocator.free(headers);
        }

        const body = if (try response.body()) |bytes|
            try self.allocator.dupe(u8, bytes)
        else
            try self.allocator.alloc(u8, 0);
        errdefer self.allocator.free(body);

        // Dusty follows redirects internally and does not expose the final
        // URI, so the reported URL is the one that was requested.
        const final_url = try self.allocator.dupe(u8, job.url);
        errdefer self.allocator.free(final_url);

        return .{
            .status = status,
            .status_text = status_text,
            .headers = headers,
            .body = body,
            .url = final_url,
        };
    }

    fn clientOf(self: *Fetch, job: *const Job) *dusty.Client {
        return job.client orelse &self.client;
    }

    /// Streams the body to JS: settle the head, then one chunk per ack. The
    /// client response stays alive until the body ends or the task unwinds.
    fn runStream(self: *Fetch, job: *Job) void {
        // Streaming events are counted individually; this releases the
        // pending slot `submit` took for the task itself.
        defer self.queue.cancel();

        var response = self.clientOf(job).fetch(job.url, requestOptions(job, true)) catch |err| {
            self.failStream(job, err);
            return;
        };
        defer response.deinit();

        job.outcome = self.copyHead(job, &response) catch |err| {
            self.failStream(job, err);
            return;
        };
        self.enqueue(job, .head, null);

        // Nothing is read from the wire until JS asks for the head's body.
        self.waitAck(job) catch |err| {
            self.failStream(job, err);
            return;
        };

        var read_buffer: [16 * 1024]u8 = undefined;
        var chunk_buffer: [16 * 1024]u8 = undefined;
        var body_reader = response.reader(&read_buffer) catch |err| {
            self.failStream(job, err);
            return;
        };

        while (true) {
            const n = body_reader.interface.readSliceShort(&chunk_buffer) catch |err| {
                self.failStream(job, body_reader.err orelse err);
                return;
            };
            if (n == 0) break;

            // The reader's buffer is reused, so each chunk is copied out.
            const chunk = self.allocator.dupe(u8, chunk_buffer[0..n]) catch {
                self.failStream(job, error.OutOfMemory);
                return;
            };
            self.enqueue(job, .chunk, chunk);
            self.waitAck(job) catch |err| {
                self.failStream(job, err);
                return;
            };
        }

        self.enqueue(job, .end, null);
    }

    fn copyHead(self: *Fetch, job: *Job, response: *dusty.ClientResponse) !Outcome {
        const status_text = try self.allocator.dupe(u8, response.statusText());
        errdefer self.allocator.free(status_text);

        const headers = try self.copyHeaders(response.headers());
        errdefer {
            freeHeaderPairs(self.allocator, headers);
            self.allocator.free(headers);
        }

        const final_url = try self.allocator.dupe(u8, job.url);
        errdefer self.allocator.free(final_url);

        // The head carries no body; the allocation keeps `free` uniform.
        const body = try self.allocator.alloc(u8, 0);

        return .{
            .status = response.statusCode(),
            .status_text = status_text,
            .headers = headers,
            .body = body,
            .url = final_url,
        };
    }

    /// Queues one streaming event. Events carry their own node, so a head that
    /// has not settled yet and a later failure can wait side by side.
    fn enqueue(self: *Fetch, job: *Job, kind: Event, chunk: ?[]u8) void {
        const event = self.allocator.create(StreamEvent) catch {
            if (chunk) |bytes| self.allocator.free(bytes);
            return;
        };
        event.* = .{
            .job = job,
            .allocator = self.allocator,
            .kind = kind,
            .chunk = chunk,
        };
        event.link = .{
            .context = event,
            .settle = settleStream,
            .abort = abortStream,
        };

        _ = job.pending_events.fetchAdd(1, .acq_rel);
        self.queue.submit(&event.link) catch {
            _ = job.pending_events.fetchSub(1, .acq_rel);
            if (chunk) |bytes| self.allocator.free(bytes);
            self.allocator.destroy(event);
            return;
        };
        self.queue.complete(&event.link);
    }

    fn failStream(self: *Fetch, job: *Job, err: anyerror) void {
        const info = classify(err);
        job.failure = .{ .err = err, .code = info.code, .errno = info.errno };
        self.enqueue(job, .failure, null);
    }

    /// Blocks until JS grants one more read. Cancellation (abort) lands here
    /// as `error.Canceled`, which unblocks the task.
    fn waitAck(self: *Fetch, job: *Job) error{Canceled}!void {
        _ = self;
        job.ack_mutex.lock() catch |err| return err;
        defer job.ack_mutex.unlock();

        while (job.ack_granted == job.ack_taken) {
            job.ack_cond.wait(&job.ack_mutex) catch |err| return err;
        }
        job.ack_taken += 1;
    }

    fn copyHeaders(self: *Fetch, headers: *const dusty.Headers) ![]HeaderPair {
        var list: std.ArrayList(HeaderPair) = .empty;
        errdefer {
            freeHeaderPairs(self.allocator, list.items);
            list.deinit(self.allocator);
        }

        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            const name = try self.allocator.dupe(u8, entry.key);
            errdefer self.allocator.free(name);
            const value = try self.allocator.dupe(u8, entry.value);
            errdefer self.allocator.free(value);
            try list.append(self.allocator, .{ .name = name, .value = value });
        }

        return list.toOwnedSlice(self.allocator);
    }

    /// Cancels every request task before releasing the client so no task can
    /// touch the pool afterwards. The queue aborts the jobs later.
    pub fn deinit(self: *Fetch, ctx: *quickjs.Context) void {
        _ = ctx;
        var iterator = self.active.valueIterator();
        while (iterator.next()) |slot| {
            const job = slot.*;
            if (job.handle) |handle| {
                job.handle = null;
                var pending = handle;
                pending.cancel();
            }
        }
        self.active_open = false;
        self.active.deinit();

        // Each client borrows its entry's PEM strings, so it must go first.
        for (self.tls_clients.items) |entry| {
            entry.client.deinit();
            freeTlsStrings(self.allocator, entry);
            self.allocator.destroy(entry);
        }
        self.tls_clients.deinit(self.allocator);
        self.client.deinit();
    }
};

const ErrorInfo = struct {
    code: [:0]const u8,
    errno: i32 = 0,
};

fn classify(err: anyerror) ErrorInfo {
    return switch (err) {
        error.InvalidUrl,
        error.UnsupportedScheme,
        => .{ .code = "ERR_INVALID_URL" },
        error.ConnectionRefused => .{ .code = "ECONNREFUSED", .errno = connectionRefusedErrno() },
        error.UnknownHostName => .{ .code = "ENOTFOUND" },
        error.TlsNotConfigured,
        error.MissingTlsConfig,
        error.NoCertificateAuthority,
        error.CertificateBundleLoadFailure,
        error.TlsInitializationFailed,
        => .{ .code = "ERR_TLS_CERT_ALTNAME_INVALID" },
        error.CertificateHostMismatch => .{ .code = "ERR_TLS_CERT_ALTNAME_INVALID" },
        error.CertificateIssuerNotFound,
        error.CertificateIssuerMismatch,
        error.CertificateSignatureAlgorithmUnsupported,
        error.CertificateSignatureAlgorithmMismatch,
        error.CertificateSignatureInvalid,
        => .{ .code = "UNABLE_TO_VERIFY_LEAF_SIGNATURE" },
        error.CertificateExpired => .{ .code = "CERT_HAS_EXPIRED" },
        error.CertificateNotYetValid => .{ .code = "CERT_NOT_YET_VALID" },
        error.HeadersTooLarge => .{ .code = "UND_ERR_HEADERS_OVERFLOW" },
        error.ResponseTooLarge, error.StreamTooLong => .{ .code = "ERR_BODY_TOO_LARGE" },
        error.Timeout => .{ .code = "ETIMEDOUT" },
        error.Canceled => .{ .code = "ABORT_ERR" },
        error.OutOfMemory => .{ .code = "ENOMEM", .errno = -12 },
        else => .{ .code = "EIO", .errno = -5 },
    };
}

fn connectionRefusedErrno() i32 {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .maccatalyst, .driverkit => -61,
        .windows => -10061,
        else => -111,
    };
}

/// Rejects the job's promise with the failure or settles it with the response.
fn settleJob(ctx: *quickjs.Context, link: *jobs.Job) void {
    const job: *Job = @ptrCast(@alignCast(link.context));
    defer job.destroy(ctx);

    if (job.failure) |failure| {
        const error_value = makeError(ctx, failure);
        defer error_value.deinit(ctx);
        settleReject(ctx, job, error_value);
        return;
    }

    const value = toValue(ctx, job.outcome.?, true) catch {
        const failure: Failure = .{ .err = error.Unexpected, .code = "EIO", .errno = -5 };
        const error_value = makeError(ctx, failure);
        defer error_value.deinit(ctx);
        settleReject(ctx, job, error_value);
        return;
    };
    defer value.deinit(ctx);

    const ignored = job.resolve.call(ctx, .undefined, &.{value});
    ignored.deinit(ctx);
}

/// Settles one streaming event: head, chunk, end, or failure.
fn settleStream(ctx: *quickjs.Context, link: *jobs.Job) void {
    const event: *StreamEvent = @ptrCast(@alignCast(link.context));
    defer event.allocator.destroy(event);

    const job = event.job;
    switch (event.kind) {
        .head => {
            if (job.outcome) |outcome| {
                if (toValue(ctx, outcome, false)) |value| {
                    defer value.deinit(ctx);
                    const ignored = job.resolve.call(ctx, .undefined, &.{value});
                    ignored.deinit(ctx);
                } else |_| {
                    const failure: Failure = .{ .err = error.Unexpected, .code = "EIO", .errno = -5 };
                    const error_value = makeError(ctx, failure);
                    defer error_value.deinit(ctx);
                    settleReject(ctx, job, error_value);
                }
            }
            job.head_settled = true;
            job.eventDone(ctx);
        },
        .chunk => {
            const bytes = event.chunk orelse &.{};
            if (job.on_chunk.isFunction(ctx)) {
                const copy = quickjs.Value.initUint8ArrayCopy(ctx, bytes);
                defer copy.deinit(ctx);
                const ignored = job.on_chunk.call(ctx, .undefined, &.{copy});
                ignored.deinit(ctx);
            }
            if (event.chunk) |owned| event.allocator.free(owned);
            event.chunk = null;
            job.eventDone(ctx);
        },
        .end => {
            if (job.on_end.isFunction(ctx)) {
                const ignored = job.on_end.call(ctx, .undefined, &.{});
                ignored.deinit(ctx);
            }
            job.terminated = true;
            job.eventDone(ctx);
        },
        .failure => {
            const failure = job.failure orelse Failure{ .err = error.Unexpected, .code = "EIO", .errno = -5 };
            const error_value = makeError(ctx, failure);
            defer error_value.deinit(ctx);

            if (job.head_settled and job.on_error.isFunction(ctx)) {
                const ignored = job.on_error.call(ctx, .undefined, &.{error_value});
                ignored.deinit(ctx);
            } else {
                settleReject(ctx, job, error_value);
            }
            job.terminated = true;
            job.eventDone(ctx);
        },
        .response => unreachable,
    }
}

fn settleReject(ctx: *quickjs.Context, job: *Job, error_value: quickjs.Value) void {
    const ignored = job.reject.call(ctx, .undefined, &.{error_value});
    ignored.deinit(ctx);
}

/// Drops a job that never got to settle, releasing its QuickJS values.
fn abortJob(ctx: *quickjs.Context, link: *jobs.Job) void {
    const job: *Job = @ptrCast(@alignCast(link.context));
    job.destroy(ctx);
}

/// Drops one queued streaming event during shutdown. The job dies with its
/// last event, so two events for the same job cannot double-free it.
fn abortStream(ctx: *quickjs.Context, link: *jobs.Job) void {
    const event: *StreamEvent = @ptrCast(@alignCast(link.context));
    defer event.allocator.destroy(event);

    if (event.chunk) |bytes| event.allocator.free(bytes);
    event.chunk = null;

    const job = event.job;
    job.terminated = true;
    job.eventDone(ctx);
}

fn toValue(ctx: *quickjs.Context, outcome: Outcome, include_body: bool) !quickjs.Value {
    const object = quickjs.Value.initObject(ctx);
    errdefer object.deinit(ctx);

    try object.setPropertyStr(ctx, "status", quickjs.Value.initInt32(@intCast(outcome.status)));
    try object.setPropertyStr(ctx, "statusText", quickjs.Value.initStringLen(ctx, outcome.status_text));
    try object.setPropertyStr(ctx, "url", quickjs.Value.initStringLen(ctx, outcome.url));
    try object.setPropertyStr(ctx, "headers", try headersValue(ctx, outcome.headers));
    if (include_body) {
        try object.setPropertyStr(ctx, "body", quickjs.Value.initUint8ArrayCopy(ctx, outcome.body));
    }
    return object;
}

/// Builds the flat `[name, value, ...]` array; ownership transfers on return.
fn headersValue(ctx: *quickjs.Context, headers: []const HeaderPair) !quickjs.Value {
    const array = quickjs.Value.initArray(ctx);
    errdefer array.deinit(ctx);

    for (headers, 0..) |header, index| {
        try array.setPropertyUint32(ctx, @intCast(index * 2), quickjs.Value.initStringLen(ctx, header.name));
        try array.setPropertyUint32(ctx, @intCast(index * 2 + 1), quickjs.Value.initStringLen(ctx, header.value));
    }
    return array;
}

fn makeError(ctx: *quickjs.Context, failure: Failure) quickjs.Value {
    var buffer: [512]u8 = undefined;
    const message: []const u8 = std.fmt.bufPrint(
        &buffer,
        "fetch failed: {s}",
        .{@errorName(failure.err)},
    ) catch "fetch failed";

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

    error_object.setPropertyStr(ctx, "code", quickjs.Value.initString(ctx, failure.code)) catch {};
    if (failure.errno != 0) {
        error_object.setPropertyStr(ctx, "errno", quickjs.Value.initInt32(failure.errno)) catch {};
    }
    error_object.setPropertyStr(ctx, "syscall", quickjs.Value.initString(ctx, "fetch")) catch {};
    return error_object;
}

test "tlsHash: stable per configuration and distinct across fields" {
    const base = tlsHash("ca-pem", null, null, true);
    try std.testing.expectEqualSlices(u8, &base, &tlsHash("ca-pem", null, null, true));

    // A different CA, a different reject flag, and absent vs empty all differ.
    try std.testing.expect(!std.mem.eql(u8, &base, &tlsHash("other-pem", null, null, true)));
    try std.testing.expect(!std.mem.eql(u8, &base, &tlsHash("ca-pem", null, null, false)));
    try std.testing.expect(!std.mem.eql(
        u8,
        &tlsHash(null, null, null, true),
        &tlsHash("", null, null, true),
    ));

    // Fields are length-prefixed, so shifting bytes between them cannot alias.
    try std.testing.expect(!std.mem.eql(
        u8,
        &tlsHash("ab", "c", null, true),
        &tlsHash("a", "bc", null, true),
    ));
}

test "TlsRequest: only the default configuration counts as empty" {
    var none: TlsRequest = .{};
    try std.testing.expect(none.isEmpty());

    var strict: TlsRequest = .{ .reject_unauthorized = false };
    try std.testing.expect(!strict.isEmpty());
}
