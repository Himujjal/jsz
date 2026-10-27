// Generic completion queue between I/O tasks and the JS task.
//
// This is a mutex + condition variable queue, not `zio.Channel`/`zio.select`.
// `zio.select` needs a task context, while tests drive this queue from the
// plain main thread. Plan §5.2 schedules the `zio.select` variant together with
// `Runtime.runMain`; this implementation is the sanctioned fallback named in
// that section, and the job protocol is identical either way.

const std = @import("std");
const quickjs = @import("quickjs");
const zio = @import("zio");

/// A unit of work handed from an I/O task back to the JS task.
pub const Job = struct {
    /// Intrusive FIFO link, owned by the queue.
    next: ?*Job = null,
    /// Owner payload (e.g. `*fs.Job`). Cast back with @ptrCast/@alignCast.
    context: *anyopaque,
    /// Runs on the JS task. Settles the promise and frees the job.
    settle: *const fn (ctx: *quickjs.Context, job: *Job) void,
    /// Runs on the JS task during shutdown. Rejects and frees the job.
    abort: *const fn (ctx: *quickjs.Context, job: *Job) void,
};

/// FIFO of completed jobs plus the count of work still in flight.
pub const Queue = struct {
    allocator: std.mem.Allocator,
    mutex: zio.os.Mutex = .init(),
    cond: zio.os.Condition = .init(),
    head: ?*Job = null,
    tail: ?*Job = null,
    pending: usize = 0,
    closed: bool = false,
    /// Set by `notify` to release a blocked waiter (e.g. a signal arrived).
    wake: bool = false,

    /// Creates an empty, open queue.
    pub fn init(allocator: std.mem.Allocator) Queue {
        return .{ .allocator = allocator };
    }

    /// Releases the synchronization primitives; jobs are not touched.
    pub fn deinit(self: *Queue) void {
        self.mutex.deinit();
        self.cond.deinit();
    }

    /// Registers in-flight work. Callable from any thread or task.
    pub fn submit(self: *Queue, job: *Job) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.closed) return error.Closed;
        job.next = null;
        self.pending += 1;
    }

    /// Undoes a `submit` whose task never started, without enqueueing the job.
    pub fn cancel(self: *Queue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.pending -= 1;
    }

    /// Appends a finished job to the completion list. Callable from an I/O task.
    pub fn complete(self: *Queue, job: *Job) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        job.next = null;
        if (self.tail) |tail| {
            tail.next = job;
        } else {
            self.head = job;
        }
        self.tail = job;
        self.pending -= 1;
        self.cond.signal();
    }

    /// True while work is in flight or a completion is waiting.
    pub fn hasWork(self: *Queue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pending > 0 or self.head != null;
    }

    /// True while work is still in flight.
    pub fn hasPending(self: *Queue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pending > 0;
    }

    /// Pops the oldest completion, if any.
    pub fn tryTake(self: *Queue) ?*Job {
        self.mutex.lock();
        defer self.mutex.unlock();

        const job = self.head orelse return null;
        self.head = job.next;
        if (self.head == null) self.tail = null;
        job.next = null;
        return job;
    }

    /// Settles every completed job on the JS task.
    pub fn dispatch(self: *Queue, ctx: *quickjs.Context) void {
        while (self.tryTake()) |job| job.settle(ctx, job);
    }

    /// Releases a blocked `wait` without enqueueing a job. Callable from any
    /// thread or task; the flag stays set until `takeWake` consumes it.
    pub fn notify(self: *Queue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.wake = true;
        self.cond.signal();
    }

    /// Consumes a pending wake-up signal.
    pub fn takeWake(self: *Queue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const woke = self.wake;
        self.wake = false;
        return woke;
    }

    /// Waits for a completion or a wake-up. A null timeout blocks until either
    /// arrives.
    pub fn wait(self: *Queue, timeout_ns: ?u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.head != null or self.wake) return;

        if (timeout_ns) |ns| {
            if (ns == 0) return;
            self.cond.timedWait(&self.mutex, .fromNanoseconds(ns)) catch {};
        } else {
            while (self.head == null and !self.wake) {
                self.cond.wait(&self.mutex);
            }
        }
    }

    /// Stops accepting jobs, waits for in-flight work, and aborts the rest.
    pub fn shutdown(self: *Queue, ctx: *quickjs.Context) void {
        self.mutex.lock();
        self.closed = true;
        while (self.pending > 0) {
            self.cond.timedWait(&self.mutex, .fromMilliseconds(5)) catch {};
        }
        var node = self.head;
        self.head = null;
        self.tail = null;
        self.mutex.unlock();

        while (node) |job| {
            const next = job.next;
            job.abort(ctx, job);
            node = next;
        }
    }
};
