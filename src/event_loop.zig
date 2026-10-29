const std = @import("std");
const quickjs = @import("quickjs");
const zio = @import("zio");
const jobs = @import("jobs.zig");

const UnhandledRejection = struct {
    promise: quickjs.Value,
    reason: quickjs.Value,
};

/// Signals the runtime watches. The enum value is also the pending bit index.
pub const SignalKind = enum(u8) {
    interrupt,
    terminate,
    hangup,

    pub const count = @typeInfo(SignalKind).@"enum".field_names.len;

    /// Node exits with 128+signum when no listener is registered.
    pub fn number(self: SignalKind) u8 {
        return switch (self) {
            .interrupt => 2,
            .terminate => 15,
            .hangup => 1,
        };
    }

    pub fn label(self: SignalKind) [:0]const u8 {
        return switch (self) {
            .interrupt => "SIGINT",
            .terminate => "SIGTERM",
            .hangup => "SIGHUP",
        };
    }

    pub fn fromLabel(name: []const u8) ?SignalKind {
        inline for (@typeInfo(SignalKind).@"enum".field_values) |value| {
            const kind: SignalKind = @fromBackingInt(@intCast(value));
            if (std.mem.eql(u8, kind.label(), name)) return kind;
        }
        return null;
    }

    pub fn zioKind(self: SignalKind) zio.SignalKind {
        return switch (self) {
            .interrupt => .interrupt,
            .terminate => .terminate,
            // Windows console control events have no hangup equivalent.
            .hangup => if (comptime @hasField(zio.SignalKind, "hangup"))
                @field(zio.SignalKind, "hangup")
            else
                .terminate,
        };
    }
};

pub const Timer = struct {
    id: u64,
    deadline_ns: u64,
    interval_ns: ?u64 = null,
    callback: ?quickjs.Value = null,
    args: ?[]quickjs.Value = null,
    resolve: ?quickjs.Value = null,
    reject: ?quickjs.Value = null,
    cancelled: bool = false,
};

pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    ctx: *quickjs.Context,
    js_rt: *quickjs.Runtime,
    list: std.ArrayList(*Timer) = .empty,
    timers: std.AutoHashMap(u64, *Timer),
    next_id: u64 = 1,
    stopped: bool = false,
    failed: bool = false,
    max_iterations: ?usize = null,
    max_runtime_ns: ?u64 = null,
    started_ns: u64,
    iterations: usize = 0,
    sink: ?*std.ArrayList(u8) = null,
    /// Shared completion queue for async work (fs today, other subsystems later).
    queue: ?*jobs.Queue = null,
    /// Node-style "keeps the process alive" counter for live I/O handles.
    ref_count: usize = 0,
    exit_code: u8 = 0,
    /// `process.on('exit')` trampoline; runs once before shutdown.
    exit_hook: ?quickjs.Value = null,
    /// `process.on('SIGINT'|'SIGTERM'|'SIGHUP')` trampolines, indexed by
    /// `@intFromEnum(SignalKind)`; null means exit 128+signum.
    signal_hooks: [SignalKind.count]?quickjs.Value = @splat(null),
    /// `process.on('uncaughtException')` trampoline; null keeps the old
    /// report-and-fail behavior.
    uncaught_hook: ?quickjs.Value = null,
    /// A watcher is always wanted: it turns a signal into Node's default exit
    /// code when no JS listener exists.
    signal_wanted: [SignalKind.count]bool = @splat(true),
    /// Bitmask written by the zio signal tasks, consumed by the JS task.
    pending_signals: std.atomic.Value(u8) = .init(0),
    /// Rejected promises that had no handler when the job queue drained.
    rejections: std.ArrayList(UnhandledRejection) = .empty,
    exit_hooks_ran: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *quickjs.Context,
        js_rt: *quickjs.Runtime,
    ) !EventLoop {
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .js_rt = js_rt,
            .timers = .init(allocator),
            .started_ns = now(),
        };
    }

    pub fn deinit(self: *EventLoop) void {
        for (self.list.items) |timer| self.destroyTimer(timer);
        self.list.deinit(self.allocator);
        self.timers.deinit();

        if (self.exit_hook) |hook| hook.deinit(self.ctx);
        for (self.signal_hooks) |maybe_hook| {
            if (maybe_hook) |hook| hook.deinit(self.ctx);
        }
        if (self.uncaught_hook) |hook| hook.deinit(self.ctx);
        for (self.rejections.items) |entry| {
            entry.promise.deinit(self.ctx);
            entry.reason.deinit(self.ctx);
        }
        self.rejections.deinit(self.allocator);
    }

    pub fn schedule(
        self: *EventLoop,
        delay_ms: u64,
        repeat: bool,
        callback: quickjs.Value,
        args: []quickjs.Value,
    ) !u64 {
        const timer = self.allocator.create(Timer) catch |err| {
            callback.deinit(self.ctx);
            for (args) |arg| arg.deinit(self.ctx);
            self.allocator.free(args);
            return err;
        };
        timer.* = .{
            .id = self.newId(),
            .deadline_ns = now() +| delayNs(delay_ms),
            .interval_ns = if (repeat) delayNs(delay_ms) else null,
            .callback = callback,
        };
        errdefer self.destroyTimer(timer);

        timer.args = args;
        try self.list.append(self.allocator, timer);
        errdefer _ = self.list.pop();
        try self.timers.put(timer.id, timer);

        return timer.id;
    }

    pub fn schedulePromise(
        self: *EventLoop,
        delay_ms: u64,
        resolve: quickjs.Value,
        reject: quickjs.Value,
    ) !u64 {
        const timer = self.allocator.create(Timer) catch |err| {
            resolve.deinit(self.ctx);
            reject.deinit(self.ctx);
            return err;
        };
        timer.* = .{
            .id = self.newId(),
            .deadline_ns = now() +| delayNs(delay_ms),
            .resolve = resolve,
            .reject = reject,
        };
        errdefer self.destroyTimer(timer);

        try self.list.append(self.allocator, timer);
        errdefer _ = self.list.pop();
        try self.timers.put(timer.id, timer);

        return timer.id;
    }

    pub fn cancel(self: *EventLoop, id: u64) bool {
        const timer = self.timers.get(id) orelse return false;
        _ = self.timers.remove(id);
        timer.cancelled = true;

        if (timer.resolve != null) self.rejectPromise(timer);
        return true;
    }

    pub fn stop(self: *EventLoop) void {
        self.stopped = true;
    }

    /// Called by a zio signal task. Only records the signal and wakes a blocked
    /// loop; the JS task runs the listener on its next iteration.
    pub fn notifySignal(self: *EventLoop, kind: SignalKind) void {
        const bit: u8 = @as(u8, 1) << @as(u3, @intCast(@backingInt(kind)));
        _ = self.pending_signals.fetchOr(bit, .release);
        if (self.queue) |queue| queue.notify();
    }

    /// Installs the JS trampoline for `kind`, replacing any previous one.
    pub fn setSignalHook(self: *EventLoop, kind: SignalKind, listener: quickjs.Value) void {
        const index = @backingInt(kind);
        if (self.signal_hooks[index]) |previous| previous.deinit(self.ctx);
        self.signal_hooks[index] = listener.dup(self.ctx);
        self.signal_wanted[index] = true;
    }

    pub fn clearSignalHook(self: *EventLoop, kind: SignalKind) void {
        const index = @backingInt(kind);
        if (self.signal_hooks[index]) |hook| hook.deinit(self.ctx);
        self.signal_hooks[index] = null;
    }

    /// True while any default-exit watcher must stay armed; the loop then waits
    /// on the queue instead of sleeping so a signal can wake it.
    pub fn signalsWatched(self: *EventLoop) bool {
        for (self.signal_wanted) |wanted| {
            if (wanted) return true;
        }
        return false;
    }

    /// Runs every pending signal's listener in delivery order, or stops with
    /// Node's default code when none is registered.
    fn handleSignals(self: *EventLoop) void {
        const mask = self.pending_signals.swap(0, .acquire);
        if (mask == 0) return;
        // `notify` leaves its wake flag set; consuming it keeps later waits
        // blocking instead of spinning the loop.
        if (self.queue) |queue| _ = queue.takeWake();

        var index: usize = 0;
        while (index < SignalKind.count) : (index += 1) {
            const bit: u8 = @as(u8, 1) << @as(u3, @intCast(index));
            if (mask & bit == 0) continue;

            const kind: SignalKind = @fromBackingInt(@intCast(index));
            const hook = self.signal_hooks[index] orelse {
                self.exit_code = 128 + kind.number();
                self.stopped = true;
                return;
            };

            const argument = quickjs.Value.initString(self.ctx, kind.label());
            defer argument.deinit(self.ctx);
            const result = hook.call(self.ctx, .undefined, &.{argument});
            defer result.deinit(self.ctx);
            if (result.isException()) _ = self.handleUncaught();
            if (self.stopped) return;
        }
    }

    /// Runs `process.on('exit')` once, in registration order (the JS trampoline
    /// owns the ordering). Exceptions are printed and never propagated.
    pub fn runExitHooks(self: *EventLoop, code: u8) void {
        if (self.exit_hooks_ran) return;
        self.exit_hooks_ran = true;

        const hook = self.exit_hook orelse return;
        const code_value = quickjs.Value.initInt32(@intCast(code));
        const result = hook.call(self.ctx, .undefined, &.{code_value});
        defer result.deinit(self.ctx);
        if (result.isException()) self.reportException();
    }

    /// Called by the promise rejection tracker. Entries are keyed by promise
    /// identity; a later handler clears the pending warning.
    pub fn trackRejection(
        self: *EventLoop,
        promise: quickjs.Value,
        reason: quickjs.Value,
        is_handled: bool,
    ) void {
        const wanted = valuePtr(promise);
        for (self.rejections.items, 0..) |entry, index| {
            if (valuePtr(entry.promise) != wanted) continue;
            if (is_handled) {
                var removed = self.rejections.swapRemove(index);
                removed.promise.deinit(self.ctx);
                removed.reason.deinit(self.ctx);
            }
            return;
        }
        if (is_handled) return;

        const entry: UnhandledRejection = .{
            .promise = promise.dup(self.ctx),
            .reason = reason.dup(self.ctx),
        };
        self.rejections.append(self.allocator, entry) catch {
            entry.promise.deinit(self.ctx);
            entry.reason.deinit(self.ctx);
        };
    }

    /// Drops pending warnings for `reason`; used when the host reports a
    /// module-evaluation rejection as an uncaught exception.
    pub fn discardRejectionsFor(self: *EventLoop, reason: quickjs.Value) void {
        var index: usize = 0;
        while (index < self.rejections.items.len) {
            const entry = self.rejections.items[index];
            if (!sameReason(self.ctx, entry.reason, reason)) {
                index += 1;
                continue;
            }
            var removed = self.rejections.swapRemove(index);
            removed.promise.deinit(self.ctx);
            removed.reason.deinit(self.ctx);
        }
    }

    /// Prints one warning per still-unhandled rejection and makes the exit code
    /// non-zero unless JS already chose one.
    pub fn reportUnhandledRejections(self: *EventLoop) void {
        for (self.rejections.items) |entry| {
            self.appendOut("UnhandledPromiseRejectionWarning: ");
            const text = entry.reason.toStringValue(self.ctx);
            if (text.isException()) {
                const pending = self.ctx.getException();
                pending.deinit(self.ctx);
            } else {
                if (text.toCString(self.ctx)) |cstr| {
                    defer self.ctx.freeCString(cstr);
                    self.appendOut(std.mem.span(cstr));
                }
                text.deinit(self.ctx);
            }
            self.appendOut("\n");
        }

        if (self.rejections.items.len > 0 and self.exit_code == 0) self.exit_code = 1;
    }

    /// Marks a live handle; the loop keeps running while any ref is held.
    pub fn ref(self: *EventLoop) void {
        self.ref_count += 1;
    }

    /// Releases a live handle; saturates at zero.
    pub fn unref(self: *EventLoop) void {
        self.ref_count -|= 1;
    }

    /// True while at least one handle keeps the loop alive.
    pub fn hasRefs(self: *EventLoop) bool {
        return self.ref_count > 0;
    }

    pub fn run(self: *EventLoop) !void {
        while (!self.stopped) {
            try self.checkLimits();
            self.handleSignals();
            if (self.stopped) break;
            self.drainJobs() catch |err| {
                self.failed = true;
                return err;
            };
            // Settling fs work enqueues promise jobs; run them before deciding
            // whether the loop has any work left.
            self.dispatchQueue();
            self.drainJobs() catch |err| {
                self.failed = true;
                return err;
            };
            // `process.exit` may have run from a callback above; do not park on
            // a live handle after the loop was asked to stop.
            if (self.stopped) break;

            const deadline = self.nextDeadline();
            const queue_pending = if (self.queue) |queue| queue.hasWork() else false;
            if (deadline == null and !queue_pending and self.ref_count == 0) break;

            const current = now();
            if (deadline) |next| {
                if (next > current) {
                    if (queue_pending) {
                        self.queue.?.wait(next - current);
                    } else if (self.signalsWatched()) {
                        // The queue is the only wait a zio signal task can wake.
                        self.waitForWake(next - current);
                    } else {
                        zio.sleep(.fromNanoseconds(next - current)) catch |err| {
                            self.failed = true;
                            return err;
                        };
                    }
                }
            } else if (queue_pending) {
                self.queue.?.wait(null);
            } else {
                // No timer and no queued work, but live handles: hang on the
                // queue instead of spinning.
                const queue = self.queue orelse break;
                queue.wait(null);
            }

            self.dispatchQueue();
            self.drainJobs() catch |err| {
                self.failed = true;
                return err;
            };
            if (self.stopped) break;

            if (self.nextDeadline()) |next| {
                if (next <= now()) {
                    self.fireDue(now()) catch |err| {
                        self.failed = true;
                        return err;
                    };
                }
            }
            self.iterations += 1;
        }

        self.dispatchQueue();
        // process.exit must not run handlers for work that was still queued.
        if (!self.stopped) {
            self.drainJobs() catch |err| {
                self.failed = true;
                return err;
            };
        }
        if (self.failed) return error.JavaScriptError;
    }

    pub fn tick(self: *EventLoop) !void {
        try self.drainJobs();
        self.dispatchQueue();
        self.fireDue(now()) catch |err| {
            self.failed = true;
            return err;
        };
        try self.drainJobs();
    }

    fn dispatchQueue(self: *EventLoop) void {
        if (self.queue) |queue| queue.dispatch(self.ctx);
    }

    fn waitForWake(self: *EventLoop, timeout_ns: ?u64) void {
        if (self.queue) |queue| {
            queue.wait(timeout_ns);
        } else if (timeout_ns) |ns| {
            zio.sleep(.fromNanoseconds(ns)) catch {};
        }
    }

    pub fn drainJobs(self: *EventLoop) !void {
        while (self.js_rt.isJobPending()) {
            _ = self.js_rt.executePendingJob() catch {
                if (!self.handleUncaught()) return error.JavaScriptError;
            };
        }
    }

    /// Reports an uncaught exception and forwards it to the JS trampoline when
    /// one is installed. Returns true when the exception was handled and the
    /// loop may continue.
    pub fn handleUncaught(self: *EventLoop) bool {
        const exception = self.ctx.getException();
        defer exception.deinit(self.ctx);
        return self.handleUncaughtValue(exception);
    }

    /// Same as `handleUncaught`, for a value that is not the pending context
    /// exception (module evaluation reports failures through its promise).
    pub fn handleUncaughtValue(self: *EventLoop, exception: quickjs.Value) bool {
        self.reportValue(exception);

        const hook = self.uncaught_hook orelse {
            self.stopped = true;
            self.failed = true;
            return false;
        };

        const result = hook.call(self.ctx, .undefined, &.{exception});
        defer result.deinit(self.ctx);
        if (result.isException()) {
            self.reportException();
            self.stopped = true;
            self.failed = true;
            return false;
        }
        return true;
    }

    pub fn reportException(self: *EventLoop) void {
        const exception = self.ctx.getException();
        defer exception.deinit(self.ctx);
        self.reportValue(exception);
    }

    fn reportValue(self: *EventLoop, exception: quickjs.Value) void {
        const name = exception.getPropertyStr(self.ctx, "name");
        defer name.deinit(self.ctx);
        const message = exception.getPropertyStr(self.ctx, "message");
        defer message.deinit(self.ctx);

        var printed_header = false;
        if (name.toCString(self.ctx)) |cstr| {
            defer self.ctx.freeCString(cstr);
            self.appendOut(std.mem.span(cstr));
            printed_header = true;
        }
        if (message.toCString(self.ctx)) |cstr| {
            defer self.ctx.freeCString(cstr);
            if (printed_header) self.appendOut(": ");
            self.appendOut(std.mem.span(cstr));
            printed_header = true;
        }
        if (printed_header) self.appendOut("\n");

        const stack = exception.getPropertyStr(self.ctx, "stack");
        defer stack.deinit(self.ctx);

        if (stack.isString()) {
            if (stack.toCString(self.ctx)) |cstr| {
                defer self.ctx.freeCString(cstr);
                self.appendOut(std.mem.span(cstr));
                self.appendOut("\n");
            }
        } else if (!printed_header) {
            if (exception.toCString(self.ctx)) |cstr| {
                defer self.ctx.freeCString(cstr);
                self.appendOut(std.mem.span(cstr));
                self.appendOut("\n");
            } else {
                self.appendOut("Uncaught JavaScript exception\n");
            }
        }
    }

    fn checkLimits(self: *EventLoop) !void {
        if (self.max_iterations) |limit| {
            if (self.iterations >= limit) return error.Timeout;
        }
        if (self.max_runtime_ns) |limit| {
            if (now() -| self.started_ns > limit) return error.Timeout;
        }
    }

    fn nextDeadline(self: *EventLoop) ?u64 {
        var best: ?u64 = null;
        var i: usize = 0;
        while (i < self.list.items.len) {
            const timer = self.list.items[i];
            if (timer.cancelled) {
                _ = self.list.swapRemove(i);
                self.destroyTimer(timer);
                continue;
            }
            if (best == null or timer.deadline_ns < best.?) best = timer.deadline_ns;
            i += 1;
        }
        return best;
    }

    fn fireDue(self: *EventLoop, current: u64) !void {
        var due: std.ArrayList(*Timer) = .empty;
        defer due.deinit(self.allocator);

        var collected = false;
        errdefer if (!collected) {
            for (due.items) |timer| self.destroyTimer(timer);
        };

        var i: usize = 0;
        while (i < self.list.items.len) {
            const timer = self.list.items[i];
            if (timer.cancelled) {
                _ = self.list.swapRemove(i);
                self.destroyTimer(timer);
                continue;
            }
            if (timer.deadline_ns > current) {
                i += 1;
                continue;
            }

            try due.append(self.allocator, timer);
            _ = self.list.swapRemove(i);
            if (timer.interval_ns == null) _ = self.timers.remove(timer.id);
        }
        collected = true;

        std.mem.sort(*Timer, due.items, {}, timerLessThan);

        for (due.items, 0..) |timer, index| {
            if (timer.cancelled) {
                self.destroyTimer(timer);
                continue;
            }

            self.invoke(timer) catch {
                self.stopped = true;
                self.failed = true;
                self.destroyTimer(timer);
                for (due.items[index + 1 ..]) |pending| self.destroyTimer(pending);
                return;
            };

            if (timer.interval_ns) |interval| {
                if (timer.cancelled) {
                    self.destroyTimer(timer);
                } else {
                    timer.deadline_ns = now() +| interval;
                    self.list.append(self.allocator, timer) catch {
                        _ = self.timers.remove(timer.id);
                        self.destroyTimer(timer);
                        self.stopped = true;
                        self.failed = true;
                    };
                }
            } else {
                self.destroyTimer(timer);
            }
        }
    }

    fn invoke(self: *EventLoop, timer: *Timer) !void {
        if (timer.resolve) |resolve| {
            const result = resolve.call(self.ctx, .undefined, &.{});
            defer result.deinit(self.ctx);
            if (result.isException() and !self.handleUncaught()) return error.JavaScriptError;

            resolve.deinit(self.ctx);
            timer.resolve = null;
            if (timer.reject) |reject| {
                reject.deinit(self.ctx);
                timer.reject = null;
            }

            try self.drainJobs();
            return;
        }

        const callback = timer.callback orelse return;
        const result = callback.call(self.ctx, .undefined, timer.args orelse &.{});
        defer result.deinit(self.ctx);
        if (result.isException() and !self.handleUncaught()) return error.JavaScriptError;

        try self.drainJobs();
    }

    fn rejectPromise(self: *EventLoop, timer: *Timer) void {
        const reject = timer.reject orelse return;
        const err = quickjs.Value.initError(self.ctx);
        const message = quickjs.Value.initString(self.ctx, "timer canceled");
        err.setPropertyStr(self.ctx, "message", message) catch {};

        const result = reject.call(self.ctx, .undefined, &.{err});
        result.deinit(self.ctx);
        err.deinit(self.ctx);

        if (timer.resolve) |resolve| {
            resolve.deinit(self.ctx);
            timer.resolve = null;
        }
        reject.deinit(self.ctx);
        timer.reject = null;

        self.drainJobs() catch {};
    }

    fn destroyTimer(self: *EventLoop, timer: *Timer) void {
        if (timer.callback) |callback| callback.deinit(self.ctx);
        if (timer.args) |args| {
            for (args) |arg| arg.deinit(self.ctx);
            self.allocator.free(args);
        }
        if (timer.resolve) |resolve| resolve.deinit(self.ctx);
        if (timer.reject) |reject| reject.deinit(self.ctx);
        self.allocator.destroy(timer);
    }

    fn newId(self: *EventLoop) u64 {
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        return id;
    }

    fn appendOut(self: *EventLoop, bytes: []const u8) void {
        if (self.sink) |sink| {
            sink.appendSlice(self.allocator, bytes) catch {};
        } else {
            std.debug.print("{s}", .{bytes});
        }
    }
};

/// Stable identity for object values (promises): the carried pointer.
fn valuePtr(value: quickjs.Value) ?*anyopaque {
    return quickjs.c.JS_VALUE_GET_PTR(value.cval());
}

/// Compares rejection reasons without invoking JS; objects and strings use
/// identity, primitives use their value.
fn sameReason(ctx: *quickjs.Context, a: quickjs.Value, b: quickjs.Value) bool {
    if (a.isObject() or a.isString()) {
        if (!(b.isObject() or b.isString())) return false;
        return valuePtr(a) == valuePtr(b);
    }
    if (a.isNumber() and b.isNumber()) {
        const left = a.toFloat64(ctx) catch return false;
        const right = b.toFloat64(ctx) catch return false;
        return left == right;
    }
    if (a.isBool() and b.isBool()) {
        const left = a.toBool(ctx) catch return false;
        const right = b.toBool(ctx) catch return false;
        return left == right;
    }
    if (a.isUndefined()) return b.isUndefined();
    if (a.isNull()) return b.isNull();
    if (a.isBigInt() and b.isBigInt()) return valuePtr(a) == valuePtr(b);
    if (a.isSymbol() and b.isSymbol()) return valuePtr(a) == valuePtr(b);
    return false;
}

fn now() u64 {
    return zio.now().toNanoseconds();
}

/// Node clamps delays at 2^31-1 ms. Annotate the clamp as `u64`: `@min` with a
/// comptime bound narrows to the smallest fitting type, and the multiply would
/// then saturate at that type's max instead of nanoseconds.
fn delayNs(ms: u64) u64 {
    const clamped: u64 = @min(ms, 2_147_483_647);
    return clamped *| std.time.ns_per_ms;
}

fn timerLessThan(_: void, a: *Timer, b: *Timer) bool {
    if (a.deadline_ns == b.deadline_ns) return a.id < b.id;
    return a.deadline_ns < b.deadline_ns;
}
