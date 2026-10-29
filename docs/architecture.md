# Architecture

> **Note (2026-10-28):** phases 0-5 add the ESM loader, async filesystem,
> process/os/crypto, child processes, TCP `net`, a dusty-backed HTTP/HTTPS
> server and client, and `fetch`. Server responses and client response bodies
> stream; request bodies and `fetch` bodies stay buffered. QuickJS still runs on
> the single JS task; file, child, network, and fetch work runs in zio tasks and
> completes through the queue described below. The core event-loop and host
> sections remain accurate; see [the plan](plan/plan.md) for the per-module
> layering.

jsz is a single-process, single-threaded JavaScript runtime. Zig owns the process and the event loop, QuickJS executes JavaScript, and zio provides the runtime clock, timers, and I/O. Every QuickJS call happens on the JS task; there is no cross-thread JavaScript access.

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
- `src/js/builtins.zig` installs the native `setTimeout`, `clearTimeout`, `setInterval`, `clearInterval`, `sleep`, `console.log`, and `console.error` before the embedded `bootstrap.js` module installs the Node-shaped globals (`console`, `performance`, `global`, `process`, `Buffer`, `URL`, `fetch`, and friends).
- `src/js/host.zig` defines the `Host` struct: allocator, QuickJS context, event loop pointer, and output buffer pointer. A `*Host` is stored in the QuickJS context opaque pointer, so C callbacks can reach runtime state without circular imports.

The public operations on an initialized runtime are `eval`, `evalFile`, `run`, `tick`, `flush`, `appendValue`, `context`, and `deinit`. `appendValue` converts a value with JavaScript `toString` and appends it plus a newline to the output buffer. `Options` accepts `max_runtime_ms`, `max_iterations`, and an optional `writer`.

The shared stdout writer is required because each `std.Io.File.stdout()` writer starts at offset 0. Creating a new writer per message would overwrite earlier output. One writer per process preserves ordering.

## JavaScript bindings

`src/js/builtins.zig` gets the global object and installs C functions for `setTimeout`, `clearTimeout`, `setInterval`, `clearInterval`, `sleep`, `console.log`, and `console.error`. Each callback recovers the `*Host` from the QuickJS context opaque pointer with `ctx.getOpaque(Host)`.

- `src/js/timers.zig` converts the delay argument to a number. `undefined`, `null`, `NaN`, and non-positive values become 0; larger values are clamped to 2,147,483,647 ms. It validates that the callback is a function, duplicates the extra arguments into an owned slice, schedules the timer, and returns the timer id as an integer. `clearTimeout` and `clearInterval` convert the first argument to an unsigned 32-bit integer and call `EventLoop.cancel`.
- `src/js/promises.zig` creates a QuickJS promise capability and schedules its resolve and reject functions with the event loop.
- `src/js/console.zig` is the native writer: it formats each argument with JavaScript `toString`, separates arguments with a space, and appends a newline to the runtime output buffer. `console.error` uses the same write path as `console.log`. `src/builtins/console.js` wraps those writers, formats through `util.format`, and adds `info`/`warn`/`debug`/`trace`/`dir`/`assert`/`time`/`timeEnd`; it replaces the global during bootstrap.

## Lifecycle

### Initialization

1. `main(init: std.process.Init)` calls `cli.run(init)`.
2. `cli.run` creates a stdout writer with a 4 KiB buffer and parses the command line.
3. `jsz.Runtime.init(init.gpa, .{ .writer = &stdout.interface })` allocates the runtime and initializes, in order, the zio Runtime, QuickJS Runtime, QuickJS Context, and EventLoop.
4. The runtime points `loop.sink` at its output buffer and applies the optional `max_iterations` and `max_runtime_ms` options.
5. It fills the `Host` struct and stores it with `ctx.setOpaque(Host, &self.host)`.
6. `builtins.register(&self.host)` installs the native functions and writer object; evaluating the embedded `bootstrap.js` then installs the public globals over them.

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

## HTTP, HTTPS, and fetch

HTTP and HTTPS share one transport: a vendored copy of dusty 0.5.0 in
`vendor/dusty`. The vendored copy differs from upstream in two places. The
server can write a status line from a numeric code plus a caller-supplied
reason phrase, and the client parser accepts status codes that dusty's `Status`
enum does not name. Everything else (accept loop, parsing, keep-alive, chunked
framing, TLS handshake) is upstream dusty.

### Server path

`src/http.zig` owns one `dusty.Server` per JavaScript `http.Server` or
`https.Server`. The dusty handler reads the request body whole, capped at
1 MiB, posts a request job to the JS task, and parks until JavaScript answers.
`src/js/http.zig` exposes the native surface and `src/builtins/http.js` layers
`IncomingMessage`, `ServerResponse`, and `Server` on top of it.

A response takes one of two paths:

- **Buffered.** If the handler never calls `write` or `flushHeaders`, `end`
  hands the accumulated body to `respond`. Dusty writes one response with a
  `Content-Length`.
- **Streamed.** The first `write` or `flushHeaders` calls `streamStart`, which
  commits the status line and headers. `streamWrite` copies a chunk into a
  per-connection queue and the native task drains it into a chunked body, so
  bytes reach the wire before `end`. `streamEnd` writes the terminating chunk
  and `streamAbort` fails the handler so the connection closes.

Backpressure is a queue with a 64 KiB high-water mark and a 16 KiB low-water
mark. `streamWrite` returns false at the high-water mark, the native task posts
a `drain` job once the queue falls below the low-water mark, and the JS facade
re-emits `drain` on the response. The facade rejects header changes after the
status line is sent with `ERR_HTTP_HEADERS_SENT`. `statusCode` accepts 100-999;
the default reason phrase is `STATUS_CODES[code] || 'unknown'`, and
`statusMessage` overrides it. A newline or carriage return in the reason phrase
raises `ERR_INVALID_CHAR`.

### Client path

`src/fetch.zig` is the single dusty client coordinator. It is used by
`fetch`, `http.request`/`http.get`, and `https.request`/`https.get`.

A client request settles in two stages. The head job carries the status line,
headers, and final URL. The body is then pulled one chunk at a time: the native
task waits for an `ack` from JavaScript before each read, reads at most 16 KiB,
and posts a chunk job. The facade (`src/builtins/http.js`) emits `data` per
chunk, then `end` and `close` at EOF, and sets `complete` only when the stream
ends. `pause` stops acking, `resume` restarts the pump, and `destroy` aborts the
native request. A body under 16 KiB therefore arrives as exactly one `data`
event.

TLS is configured per request, not per client. Each request carries a
`TlsRequest` with `ca`, `cert`, `key`, and `reject_unauthorized`.
`Fetch.clientFor` hashes those fields and keeps one `dusty.Client` per distinct
configuration, because the TLS config and the connection pool are client-wide.
`servername` is accepted by the facade and ignored; dusty derives the SNI name
from the URL.

### TLS server options and PFX

`https.createServer` branches to a TLS listener when `src/http.zig` receives a
`TlsMaterial`. `src/builtins/https.js` resolves the options before that point:

| Option | Behavior |
| --- | --- |
| `cert` + `key` | PEM string, `Buffer`, or `ArrayBuffer` |
| `pfx` + `passphrase` | parsed by `src/pkcs12.zig` into a PEM chain and PKCS#8 key |
| `ca` | string, `Buffer`, or array, joined into one PEM bundle |
| `requestCert` | enables dusty's `client_auth`; `ca` is required |
| `rejectUnauthorized` | `.require` client certificates when true, `.request` when false |

`src/pkcs12.zig` is a pure-Zig PKCS#12 reader. It handles plaintext, PBES2
(AES-CBC), and legacy PKCS#12 PBE (SHA-1 with 3DES or RC2), plus cert bags, key
bags, and shrouded key bags. It carries its own DES, RC2, and AES block ciphers:
Zig 0.17 std has no DES or RC2, and its AES covers only 128/256-bit keys while
PFX files may use AES-192. It skips MAC verification, so a wrong passphrase is
detected by decryption padding instead, and it rejects RC4 PFX and non-AES
PBES2 schemes.

## Dependencies and toolchain

Dependencies are pinned by commit in `build.zig.zon`:

- `Inqnuam/zig-quickjs-ng`
- `lalinsky/zio`
- `lalinsky/dusty` 0.5.0, vendored under `vendor/dusty` with the status-line
  and parser patch

The project targets Zig 0.17.0 and links libc. The build produces a single `jsz` executable.
