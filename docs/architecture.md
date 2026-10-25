# Architecture

jsz is a single-process, single-threaded JavaScript runtime. Zig owns the process and the event loop, QuickJS executes JavaScript, and zio provides the runtime clock and sleeping. Every QuickJS call happens on the main zio task; there is no cross-thread JavaScript access.

## Components

```text
+------------------+          +----------------------+
| src/main.zig     |          | shared stdout writer |
| std.process.Init |          | (one per process)    |
+--------+---------+          +----------+-----------+
         |                               ^
         v                               |
+------------------+                     |
| src/cli/cli.zig  |---------------------+
| parse, dispatch  |
+--------+---------+
         |
         v
+------------------+          +----------------------+
| src/runtime.zig  |<-------->| QuickJS Runtime      |
| Runtime          |          | QuickJS Context      |
+---+----------+---+          +----------+-----------+
    |          |                         ^
    v          v                         |
+---------+ +----------------+            |
|EventLoop| | output buffer  |            |
|timers   | | optional writer|            |
+----+----+ +----------------+            |
     |                                   |
     v                                   |
+------------------+                     |
| zio Runtime      |                     |
| sleep and timers |                     |
+------------------+                     |
                                         |
+------------------+                     |
| src/js/builtins  |---------------------+
| installs globals |
+---+----------+---+
    |          |
    v          v
+---------+ +-----------+
| timers  | | promises  |
| console | |           |
+----+----+ +-----+-----+
     |            |
     +-----+------+
           v
     +-----------+
     | Host      |
     | opaque ptr|
     +-----------+
           |
           +--> EventLoop, output buffer, QuickJS context
```

Arrows show calls and ownership. QuickJS invokes the installed C callbacks; each callback recovers the `Host` from the context opaque pointer.

- `src/main.zig` receives `std.process.Init` and delegates to `src/cli/cli.zig`.
- `src/cli/cli.zig` parses arguments, creates one shared stdout writer, starts the runtime, and dispatches to script, eval, or REPL mode.
- `src/runtime.zig` owns the zio Runtime, the QuickJS Runtime and Context, the EventLoop, an output buffer, and an optional `std.Io.Writer`.
- `src/event_loop.zig` schedules timers, drains QuickJS jobs, and enforces run limits.
- `src/js/builtins.zig` installs `setTimeout`, `clearTimeout`, `setInterval`, `clearInterval`, `sleep`, `console.log`, and `console.error` on the global object.
- `src/js/host.zig` defines the `Host` struct: allocator, QuickJS context, event loop pointer, and output buffer pointer. A `*Host` is stored in the QuickJS context opaque pointer, so C callbacks can reach runtime state without circular imports.

The public operations on an initialized runtime are `eval`, `evalFile`, `run`, `tick`, `flush`, `appendValue`, `context`, and `deinit`. `appendValue` converts a value with JavaScript `toString` and appends it plus a newline to the output buffer. `Options` accepts `max_runtime_ms`, `max_iterations`, and an optional `writer`.

The shared stdout writer is required because each `std.Io.File.stdout()` writer starts at offset 0. Creating a new writer per message would overwrite earlier output. One writer per process preserves ordering.

## JavaScript bindings

`src/js/builtins.zig` gets the global object and installs C functions for `setTimeout`, `clearTimeout`, `setInterval`, `clearInterval`, `sleep`, `console.log`, and `console.error`. Each callback recovers the `*Host` from the QuickJS context opaque pointer with `ctx.getOpaque(Host)`.

- `src/js/timers.zig` converts the delay argument to a number. `undefined`, `null`, `NaN`, and non-positive values become 0; larger values are clamped to 2,147,483,647 ms. It validates that the callback is a function, duplicates the extra arguments into an owned slice, schedules the timer, and returns the timer id as an integer. `clearTimeout` and `clearInterval` convert the first argument to an unsigned 32-bit integer and call `EventLoop.cancel`.
- `src/js/promises.zig` creates a QuickJS promise capability and schedules its resolve and reject functions with the event loop.
- `src/js/console.zig` formats each argument with JavaScript `toString`, separates arguments with a space, and appends a newline to the runtime output buffer. `console.error` uses the same write path as `console.log`.

## Lifecycle

### Initialization

1. `main(init: std.process.Init)` calls `cli.run(init)`.
2. `cli.run` creates a stdout writer with a 4 KiB buffer and parses the command line.
3. `jsz.Runtime.init(init.gpa, .{ .writer = &stdout.interface })` allocates the runtime and initializes, in order, the zio Runtime, QuickJS Runtime, QuickJS Context, and EventLoop.
4. The runtime points `loop.sink` at its output buffer and applies the optional `max_iterations` and `max_runtime_ms` options.
5. It fills the `Host` struct and stores it with `ctx.setOpaque(Host, &self.host)`.
6. `builtins.register(&self.host)` installs the global functions and the `console` object.

### Evaluation

`Runtime.eval(source, filename)` copies the source into a sentinel-terminated buffer with `dupeSentinel(u8, source, 0)`. `Runtime.evalFile(path)` reads the file with a sentinel using `readFileAllocOptions`, and also creates a sentinel-terminated filename.

QuickJS requires `input[input_len] == 0`. Do not remove the sentinel copy or the sentinel read; passing a non-terminated slice is invalid.

Both paths call `evalTerminated`, which evaluates the source, checks for an exception, reports it, deinitializes the result, and returns `error.JavaScriptError` when evaluation fails. On success it returns a `quickjs.Value` that the caller owns and must deinitialize.

### Run loop

`Runtime.run()` calls `EventLoop.run()` and then `Runtime.flush()`. The event loop runs until no timers remain, the loop stops, or a guard or JavaScript error fires.

`Runtime.tick()` performs one non-blocking loop turn for the REPL: it drains pending jobs, fires timers that are already due, and drains jobs again. It does not sleep waiting for future deadlines.

### Flush

`Runtime.flush()` writes the accumulated output buffer to the configured writer and flushes it. If no writer was supplied, it creates a stdout writer for that flush. The buffer is cleared with `clearRetainingCapacity`.

### Deinitialization

`Runtime.deinit()` flushes any remaining output, deinitializes the event loop, QuickJS Context, QuickJS Runtime, and zio Runtime, frees the output buffer, and destroys the runtime allocation.

## Event loop algorithm

Timers are stored in an `ArrayList` of `*Timer` records and indexed by id in a hash map. Each record holds:

- `id`
- `deadline_ns`
- optional `interval_ns`
- callback value
- argument slice
- optional `resolve` and `reject` promise functions
- `cancelled` flag

The run loop repeats these steps:

1. Check `max_iterations` and `max_runtime_ms`. Return `error.Timeout` if either guard is exceeded.
2. Drain pending QuickJS jobs.
3. Scan the timer list, remove cancelled timers, and find the earliest deadline. If no timer remains, stop.
4. If the earliest deadline is in the future, sleep with zio until it.
5. Collect all timers whose deadline is due, remove them from the active list, and sort them by deadline and then by id.
6. Fire each due timer in order. A timer with a resolve function resolves its promise; a callback timer is called with its stored arguments. QuickJS jobs are drained after each invocation.
7. Re-arm intervals with a new deadline of `now + interval_ns`. Destroy one-shot timers after firing.
8. Increment the iteration count and repeat.

If a timer callback or promise job throws, the loop stops, reports the exception, and surfaces `error.JavaScriptError`.

Cancellation removes the timer from the id map immediately, marks it cancelled, and rejects a pending promise with an `Error` whose message is `timer canceled`. Cancelled records are removed from the list during the next scan or fire pass. Timer delays are clamped to 2,147,483,647 ms in both the JavaScript binding and the event loop.

## Promise integration

`sleep(ms)` creates a QuickJS promise capability with `quickjs.Value.initPromiseCapability`. The capability's resolve and reject functions are stored on a timer through `EventLoop.schedulePromise`, and the promise value is returned to JavaScript. When the timer fires, the loop calls resolve with no arguments and deinitializes the stored functions.

The runtime does not implement `then`, `catch`, `finally`, `Promise.all`, or `async` / `await` itself. QuickJS provides those. jsz supplies only the `sleep` promise and the job pump.

Job draining is a loop over `js_rt.isJobPending()` and `js_rt.executePendingJob()`. Jobs are drained before the loop looks for the next deadline and after each timer callback. As a result, promise microtasks run before the next timer. For example, a `Promise.resolve().then(...)` queued before a `setTimeout(..., 0)` runs first.

## Error handling and limits

- An exception from `eval` or `evalFile` is reported and returned as `error.JavaScriptError`.
- An uncaught exception in a timer callback or promise job reports the exception, stops the loop, and returns `error.JavaScriptError`.
- Exception output is `Name: message` followed by the JavaScript stack when the exception has one. If neither name nor message can be printed and the stack is not a string, the exception is converted to a string; the final fallback is `Uncaught JavaScript exception`.
- The CLI prints `jsz: <ErrorName>` for an error that reaches `main` and exits with status 1.
- `max_iterations` limits loop turns. `max_runtime_ms` limits wall-clock runtime from event loop creation. Either guard returns `error.Timeout`.
- Timer delays are clamped to 2,147,483,647 ms.
- Timer callbacks are validated. A missing callback raises `callback is required`; a non-function raises `callback must be a function`.

## Ownership and memory

- A `Timer` owns its callback value, argument slice, and resolve/reject values.
- `src/js/timers.zig` allocates the argument slice and duplicates each argument. The event loop takes ownership and frees the values and the slice exactly once in `destroyTimer`.
- Interval timers keep their callback and arguments across firings. They are freed only when the interval is cancelled or the loop is deinitialized.
- The `Host` struct holds borrowed pointers. It must not outlive the `Runtime` that owns the event loop, output buffer, and QuickJS context.
- The runtime output buffer is owned by `Runtime`; the writer is borrowed and may be null.
- `Runtime.eval` owns its sentinel copy only for the duration of the call. `evalFile` owns both the sentinel source and sentinel filename for the duration of the call.
- QuickJS values returned to callers are owned by the caller and must be deinitialized with the runtime context.

## Dependencies and toolchain

Dependencies are pinned by commit in `build.zig.zon`:

- `Inqnuam/zig-quickjs-ng`
- `lalinsky/zio`

The project targets Zig 0.17.0 and links libc. The build produces a single `jsz` executable.
