const std = @import("std");
const quickjs = @import("quickjs");
const zio = @import("zio");
const Fs = @import("fs.zig").Fs;

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
    fs: ?*Fs = null,
    exit_code: u8 = 0,

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

    pub fn run(self: *EventLoop) !void {
        while (!self.stopped) {
            try self.checkLimits();
            self.drainJobs() catch |err| {
                self.failed = true;
                return err;
            };
            self.dispatchFs();

            const deadline = self.nextDeadline();
            const fs_pending = if (self.fs) |fs| fs.hasWork() else false;
            if (deadline == null and !fs_pending) break;

            const current = now();
            if (deadline) |next| {
                if (next > current) {
                    if (fs_pending) {
                        self.fs.?.wait(next - current);
                    } else {
                        zio.sleep(.fromNanoseconds(next - current)) catch |err| {
                            self.failed = true;
                            return err;
                        };
                    }
                }
            } else {
                self.fs.?.wait(null);
            }

            self.dispatchFs();
            self.drainJobs() catch |err| {
                self.failed = true;
                return err;
            };

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

        self.dispatchFs();
        if (self.failed) return error.JavaScriptError;
    }

    pub fn tick(self: *EventLoop) !void {
        try self.drainJobs();
        self.dispatchFs();
        self.fireDue(now()) catch |err| {
            self.failed = true;
            return err;
        };
        try self.drainJobs();
    }

    fn dispatchFs(self: *EventLoop) void {
        if (self.fs) |fs| fs.dispatch(self.ctx);
    }

    pub fn drainJobs(self: *EventLoop) !void {
        while (self.js_rt.isJobPending()) {
            _ = self.js_rt.executePendingJob() catch |err| {
                self.reportException();
                return err;
            };
        }
    }

    pub fn reportException(self: *EventLoop) void {
        const exception = self.ctx.getException();
        defer exception.deinit(self.ctx);

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
            if (result.isException()) {
                self.reportException();
                return error.JavaScriptError;
            }

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
        if (result.isException()) {
            self.reportException();
            return error.JavaScriptError;
        }

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
