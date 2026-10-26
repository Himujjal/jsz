# jsz Node.js 90% compatibility plan

Status: draft for implementation
Target runtime: Zig 0.17.0, QuickJS-ng (pinned in `build.zig.zon`), zio 0.19.0
Target Node semantics: Node.js 22 LTS, POSIX first, Windows best-effort

This document is a research and implementation plan. It changes no code. It
records what exists today, the architecture required to reach the agreed 90%
Node.js API set, the exact zio/Zig APIs each capability needs, and a phased
milestone plan with exit criteria.

---

## 1. Summary

jsz today is a single-source JavaScript runner with timers, native promises,
and a timer-only event loop. It has no module system, no filesystem, no
network, and no Node builtins.

The 90% target adds:

| Area | Modules |
| --- | --- |
| Module system | ESM `import` / `export`, builtin specifiers with and without `node:` |
| Paths | `path` (posix + win32) |
| Filesystem | `fs` callback API and `fs/promises` (async only); file and directory operations |
| Process | `process` globals and lifecycle |
| Children | `child_process` sync and async |
| URLs | `URL`, `URLSearchParams`, `node:url` helpers |
| HTTP | `http.createServer`, global `fetch` over HTTP and HTTPS |
| Crypto | `crypto.createHash`, `createHmac`, `randomBytes`, `randomUUID`, `randomInt`, `getRandomValues` |
| Utilities | `util`, `events` |
| OS | `os` |
| Binary | `Buffer`, `TextEncoder`, `TextDecoder`, `atob`, `btoa` |
| Globals | `console`, timers, `JSON`, `Promise` (already present), `fetch`, `process`, `Buffer` |

`fs` is asynchronous only: the callback API and `fs/promises` are implemented,
and `*Sync` entry points throw `ERR_METHOD_NOT_IMPLEMENTED` (§1.1, §7.2).

The last 10% is explicitly deferred: full streams, `https.request`,
`https.createServer`, ciphers/key generation/signing, `webcrypto.subtle`,
`crypto.timingSafeEqual`, `fs.watch`, `net`, `tls`, `dns`, `zlib`,
`worker_threads`, `readline`, `assert`.

### 1.1 Core design decisions

| Decision | Rationale |
| --- | --- |
| ESM only; no CommonJS, no `require`, no `node_modules` | QuickJS already parses modules; CJS would require a second evaluator and resolution rules we do not need. |
| Canonicalize every builtin to a `node:` specifier (`fs` -> `node:fs`) | One cache key, one loader path, identical behavior for `fs` and `node:fs`. |
| Pure-JS builtins are embedded ESM sources (`path`, `util`, `events`, `buffer`, wrappers) | Dogfoods the module system, keeps code in one language, avoids C boundary churn. |
| Native capabilities live in private C modules (`node:_fs`, `node:_encoding`, ...) | Keeps the public surface in JS where option parsing/encoding lives, native code only for syscalls. |
| Public builtins export both named bindings and a `default` namespace object | Matches Node core module interop (`import fs from 'node:fs'`). |
| All QuickJS access happens on one thread of control: the "JS task" in production | QuickJS is not thread-safe; zio's default is one executor, which we keep. |
| Async work runs in zio tasks that touch only host buffers, never QuickJS | No cross-task JS values, no locking. Completions are delivered as messages. |
| `fs` is async-only; no `*Sync` entry points | Every fs call runs in a zio I/O task, so a slow syscall can never stall timers or the event loop. `*Sync` names throw `ERR_METHOD_NOT_IMPLEMENTED`; `existsSync` is absent. |
| `std.Io` is the syscall surface, implemented by zio (`Runtime.io()`) | `std.Io.Dir`, `std.process.spawn`, `std.http.Client/Server` all run over zio without adapter code. |
| `http.createServer` only; no `https.createServer` | Zig std has a TLS client, not a TLS server. |
| `fetch` buffers the response body | Correct for the 90% set; streaming bodies are part of the deferred stream work. |

---

## 2. Current state

### 2.1 What works

- `src/runtime.zig` owns the zio runtime, QuickJS runtime/context, output
  buffer, and an `EventLoop`.
- `src/event_loop.zig` runs timers with `zio.sleep`, drains QuickJS jobs, and
  reports exceptions.
- `src/js/builtins.zig` installs global `setTimeout`, `clearTimeout`,
  `setInterval`, `clearInterval`, `sleep`, and `console`.
- `src/cli/cli.zig` parses `-e/--eval`, `-h`, `-v`, a script path, or `repl`.
- `tests/zig/` covers runtime, timers, promises, and JS fixtures.

### 2.2 What is missing

- No module loader is registered. `Runtime.evalTerminated` calls
  `ctx.eval(source, filename, .{})`, which is script mode. `import` parses but
  fails at resolution.
- No filesystem, process, network, crypto, or OS surface.
- The event loop can only wait for timers. There is no wake-up path for I/O
  completions.
- `Host` (`src/js/host.zig`) only carries allocator, context, loop, and output.
- The CLI parses argv separately from the runtime, so `process.argv` cannot be
  derived today.

### 2.3 What is already usable

- `Runtime.evalFile` already reads through
  `std.Io.Dir.cwd().readFileAllocOptions(self.zio_rt.io(), ...)`. The `std.Io`
  bridge over zio is therefore already proven for file reads.
- `zio.sleep` in the event loop already works both inside and outside a zio
  task.
- The QuickJS Zig wrapper exposes `Runtime.setModuleLoaderFunc`,
  `ModuleDef.init/addExport/setExport/getImportMeta/getNamespace`, and
  `Context.eval` with `EvalFlags{ .type = .module, .compile_only = true }`.

---

## 3. Target architecture

### 3.1 Layers

```text
┌──────────────────────────────────────────────────────────────┐
│ JavaScript builtins (embedded ESM)                           │
│ path  util  events  buffer  fs  fs/promises  url  http        │
└───────────────────────────┬──────────────────────────────────┘
                            │ import / FFI-free JS
┌───────────────────────────▼──────────────────────────────────┐
│ Private native modules (QuickJS C modules)                   │
│ node:_encoding  node:_fs  node:_process  node:_crypto        │
│ node:_http  node:_child_process  node:_url                   │
└───────────────────────────┬──────────────────────────────────┘
                            │ Zig
┌───────────────────────────▼──────────────────────────────────┐
│ jsz runtime                                                  │
│ runtime.zig  module.zig  event_loop.zig  jobs.zig            │
│ js/host.zig  js/value.zig (marshalling)  js/errors.zig       │
└───────────────────────────┬──────────────────────────────────┘
                            │ std.Io + zio primitives
┌───────────────────────────▼──────────────────────────────────┐
│ zio 0.19.0 (executor, tasks, select, channels, signals)      │
│ std.Io vtable: fs, process, net, http, random                │
└──────────────────────────────────────────────────────────────┘
```

### 3.2 Threading model

One zio executor (`RuntimeOptions{ .executors = .exact(1) }`, the default).
One "JS task" owns the QuickJS context for its whole lifetime.

- Production entry: `Runtime.runMain()` spawns `jsMain` on the zio runtime and
  joins it. `jsMain` evaluates the entry module and then runs the event loop,
  so evaluation and callbacks are literally on the same task.
- `Runtime.eval` stays available for unit tests that do not start the loop. It
  runs on the calling thread and must not be used while `jsMain` is running.
  The invariant is "never two threads touch QuickJS", not "a task object
  always exists".
- The JS task runs: entry evaluation, the event loop, timer callbacks, promise
  jobs, and all native callbacks invoked from JS.
- I/O tasks run only Zig code. They never allocate, read, or free QuickJS
  values. They write results into heap-allocated `Job` structs and send the
  pointer through a `zio.Channel(*Job)`.
- The JS task drains the channel, constructs JS values, settles promises, and
  frees the jobs.
- No fs call runs on the JS task. Every fs operation is dispatched to an I/O
  task, so a slow read cannot stall timers, promise jobs, or other callbacks.

### 3.3 The `std.Io` bridge

`zio.Runtime.io()` returns a `std.Io` whose vtable is implemented by zio. This
is the single most important integration point:

- `std.Io.Dir` gives all filesystem operations.
- `std.process.spawn(io, ...)` and `Child.wait(io)` give child processes.
- `std.http.Client{ .io = io }` gives `fetch` and HTTPS.
- `std.Io.net.IpAddress.listen(io, ...)` + `std.http.Server` give
  `http.createServer`.
- `std.Io.randomSecure(io, buf)` gives `crypto.randomBytes`.

Outside a zio task these calls take zio's blocking fallback
(`ev.executeBlocking`). Inside a task they suspend. Both paths work, so the
module loader and eval can stay synchronous.

### 3.4 New source layout

```text
src/module.zig              normalizer, resolver, loader, builtin registry
src/jobs.zig                Job union, completion channel, dispatch
src/js/builtin/             embedded ESM sources
  path.js  util.js  events.js  buffer.js
  fs.js  fs_promises.js  url.js  http.js  process.js  os.js  crypto.js
  child_process.js  encoding.js
src/js/native/              Zig implementations of private C modules
  encoding.zig  fs.zig  process.zig  crypto.zig
  http.zig  child_process.zig  url.zig
src/js/value.zig            value <-> Zig conversions, JS error construction
src/js/errors.zig           errno codes and Node-style messages
```

Build changes are additive: embedded files are picked up by `@embedFile`, so
`build.zig` needs no new steps beyond `link_libc` on test artifacts that use
libc-backed OS info (see §8.8).

---

## 4. Module system

### 4.1 Entry point and mode detection

| Input | Mode |
| --- | --- |
| `script.mjs` | module, always |
| `script.cjs` | script, always |
| `script.js` | `quickjs.detectModule(source)` -> module if true, else script |
| `-e/--eval <code>` | `quickjs.detectModule(source)` |
| REPL line | script |
| `import()` from a script | module loader is available; resolve per §4.3 |

`detectModule` is a parser-based check for top-level `import`/`export`, not a
substring check, so strings containing "import" do not trigger module mode.
This mirrors Node's `--experimental-detect-module` behavior, which we adopt
unconditionally. A malformed module still fails with a syntax error.

### 4.2 Builtin specifier table

Every public specifier canonicalizes to a `node:` name. The table is the single
source of truth for both the normalizer and the loader.

| User specifier | Canonical name | Implementation |
| --- | --- | --- |
| `fs`, `node:fs` | `node:fs` | `fs.js` + `node:_fs` |
| `fs/promises`, `node:fs/promises` | `node:fs/promises` | `fs_promises.js` + `node:_fs` |
| `path`, `node:path` | `node:path` | `path.js` |
| `path/posix`, `node:path/posix` | `node:path/posix` | `path.js` |
| `path/win32`, `node:path/win32` | `node:path/win32` | `path.js` |
| `url`, `node:url` | `node:url` | `url.js` + `node:_url` |
| `util`, `node:util` | `node:util` | `util.js` |
| `events`, `node:events` | `node:events` | `events.js` |
| `os`, `node:os` | `node:os` | `os.js` + `node:_process` |
| `process`, `node:process` | `node:process` | `process.js` + `node:_process` |
| `crypto`, `node:crypto` | `node:crypto` | `crypto.js` + `node:_crypto` |
| `child_process`, `node:child_process` | `node:child_process` | `child_process.js` + `node:_child_process` |
| `http`, `node:http` | `node:http` | `http.js` + `node:_http` |
| `buffer`, `node:buffer` | `node:buffer` | `buffer.js` + `node:_encoding` |
| `node:_encoding`, `node:_fs`, `node:_process`, `node:_crypto`, `node:_http`, `node:_child_process`, `node:_url` | same | private C modules |

Private names are loadable only by embedded sources. The normalizer rejects a
`node:_`-prefixed specifier that did not originate from an embedded module
(compare the importer's canonical name against the builtin registry). This is
not a security boundary, only a guard against user code depending on internals.

Not in the table on purpose: `stream`, `net`, `tls`, `dns`, `zlib`,
`worker_threads`, `readline`, `assert`, `https`, `http2`, `vm`, `module`,
`perf_hooks`, `timers/promises`.

### 4.3 Resolution algorithm

`normalize(base, specifier)` returns a canonical module name:

1. If `specifier` starts with `node:`:
   - look it up in the builtin table (including private names),
   - unknown -> throw `ERR_UNKNOWN_BUILTIN_MODULE`.
2. If `specifier` is a bare name in the builtin table -> return `node:<name>`.
3. If `specifier` starts with `./`, `../`, `/`, or `file:`:
   - resolve against the importer's URL:
     - importer is `file://...` -> resolve relative to its directory,
     - importer is `node:...` -> throw `ERR_INVALID_MODULE_SPECIFIER`
       (builtins cannot have relative imports),
   - canonicalize to an absolute `file://` URL with percent-encoding,
   - existence check with extension and index probing (below).
4. Otherwise throw `ERR_MODULE_NOT_FOUND` with a message that npm package
   resolution is not supported.

File probing order for a specifier without an extension:

```text
<path>            (exact)
<path>.js
<path>.mjs
<path>/index.js
<path>/index.mjs
```

`.cjs` is deliberately absent: it is script-mode only at the entry point and
cannot be imported, because there is no CommonJS loader.

There is no `package.json` `exports`/`main` handling and no `node_modules`
walk. Directory resolution is limited to the two index names above. This is
intentional and documented in `docs/roadmap.md`.

Canonical file names must be stable across imports: `./a.js` and `./a.mjs` are
different modules, but `./a.js` and `/abs/dir/a.js` are the same module. Using
an absolute `file://` URL as the key gives that for free, and QuickJS caches by
name.

### 4.4 Loader implementation

`src/module.zig` owns:

```zig
pub const Source = union(enum) {
    js: []const u8,        // embedded or file contents
    c: *const fn (*Context, *ModuleDef) bool,
};

pub fn normalize(host: *Host, ctx: *Context, base: [:0]const u8, spec: [:0]const u8) ?[*:0]u8;
pub fn load(host: *Host, ctx: *Context, name: [:0]const u8) ?*ModuleDef;
```

`normalize` returns memory allocated with QuickJS's allocator. The simplest
correct way to get such memory from Zig is to round-trip through a JS string:

```zig
const value = quickjs.Value.initStringLen(ctx, canonical);
defer value.deinit(ctx);
const cstr = value.toCString(ctx) orelse return null; // js_malloc'd
return @constCast(cstr);                      // caller (QuickJS) frees with js_free
```

Do not free the returned pointer. QuickJS frees normalizer results with
`js_free`, and `JS_ToCString` uses the same allocator, so this is legal and
avoids depending on whether translate-c exposed `js_malloc`.

`load`:

1. Builtin -> return the registered `*ModuleDef`:
   - pure JS: `compileEmbedded(ctx, name, source)`,
   - native: `ModuleDef.init(ctx, name, initFn)` followed by one
     `m.addExport(ctx, "name")` per export; `initFn` runs at instantiation and
     calls `setExport`.
2. File -> read bytes (see §4.7), then:
   ```zig
   const v = ctx.eval(source, filename, .{ .type = .module, .compile_only = true });
   if (v.isException()) return null;            // exception already pending
   const m = moduleDefFromCompiled(v) orelse return null; // §4.5
   v.deinit(ctx);
   setImportMeta(m, canonical_url, is_main);
   return m;
   ```
3. On failure, leave a QuickJS exception pending and return null. QuickJS
   turns it into the usual module-resolution error.

`Context.loadModule` exists but takes a basename and re-enters the loader; the
compile-only `eval` path above is the one we control and test. `Context.eval`
returns an *exception* value (not null) on parse errors, so check
`v.isException()` and leave the exception pending for QuickJS to surface.

Circular imports, live bindings, and namespace objects are QuickJS's job; the
loader only produces `*ModuleDef`s.

### 4.5 Prerequisite: `*ModuleDef` from a compiled module value

This is a hard blocker and must be solved in Phase 0.

QuickJS returns a compiled module as a `JSValue` whose pointer payload is a
`JSModuleDef *`. Upstream's `js_module_loader` does:

```c
func_val = JS_Eval(ctx, buf, len, filename, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
m = JS_VALUE_GET_PTR(func_val);
JS_FreeValue(ctx, func_val);
return m;
```

The pinned Zig wrapper has `Value.isModule()` but no way to extract the
pointer, and no `Context.compileModule`. Options, in order of preference:

1. Use the exported C namespace from jsz:
   ```zig
   fn toModuleDef(v: quickjs.Value) ?*quickjs.ModuleDef {
       if (!v.isModule()) return null;
       return @ptrCast(quickjs.c.JS_VALUE_GET_PTR(v.cval()));
   }
   ```
   `quickjs.c` is re-exported by the wrapper (`pub const c = @import("quickjs_c")`).
   Whether translate-c emits `JS_VALUE_GET_PTR` as a callable function must be
   checked in Phase 0; function-like macros are usually translated, but this is
   not guaranteed.
2. If the macro is unavailable, vendor a two-line patch to the dependency:
   ```zig
   pub fn toModuleDef(self: Value) ?*ModuleDef { ... }
   ```
   and point `build.zig.zon` at a fork or a pinned commit containing it.
3. Do not reimplement `JSValue` bit layout in jsz. It is not stable across
   QuickJS configurations.

Acceptance for the spike: compile `export const x = 1;`, extract the
`*ModuleDef`, return it from a loader, and `import` it from another module.

### 4.6 Embedded JS modules

Each pure-JS builtin is a file under `src/js/builtin/` compiled with
`@embedFile`:

```zig
const source = @embedFile("builtin/path.js");
```

Rules for embedded sources:

- They may import only `node:` specifiers (public or private). Relative imports
  are rejected, which keeps the embedded graph flat and cache-key-stable.
- Every public builtin ends with a default export equal to its namespace:
  ```js
  export default { join, resolve, dirname, ... };
  ```
  Node gives `import fs from 'node:fs'` a synthetic default; we match it
  explicitly.
- No top-level `await` in embedded modules. They must initialize synchronously
  so the first `import` cannot deadlock the loop.
- Keep them dependency-free and side-effect free; they are imported in tests
  that do not start the event loop.

### 4.7 Reading module files

Module loading happens on the JS task, inside a QuickJS callback, which is a
synchronous C call. Two cases:

- **No current zio task** (evals from tests, CLI startup): `std.Io.Dir` takes
  zio's blocking fallback. Safe.
- **Inside the JS task** (dynamic `import()` from a timer or a top-level import
  during loop-driven evaluation): the read suspends the JS task. No other task
  touches QuickJS, so this is safe; completions simply queue until the loader
  returns.

Use `std.Io.Dir.cwd().readFileAllocOptions(io, path, allocator, .limited(16 MiB), .of(u8), 0)`
and convert the path to a filesystem path from the canonical `file://` URL.
If a future zio version disallows suspension from a native callback, the
fallback is `host.zio_rt.blockingIo()`, which is explicitly designed for this.
This read belongs to the loader, not the `fs` builtin: it calls `std.Io.Dir`
directly, so the async-only `fs` surface does not apply here.

### 4.8 `import.meta`

For every module, after compilation:

- `url`: the canonical `file://` URL or `node:` name.
- `main`: `true` only for the entry module.
- `resolve`: not implemented in v1; it would need a synchronous resolver
  exposed to JS. Document as unsupported.

`ModuleDef.getImportMeta(ctx)` returns a new `Value`; set both properties and
deinit. For C modules, set them inside the module init callback.

### 4.9 Errors

| Condition | Error |
| --- | --- |
| Unknown `node:` builtin | `ERR_UNKNOWN_BUILTIN_MODULE` |
| Bare non-builtin specifier | `ERR_MODULE_NOT_FOUND` |
| Relative import missing after probing | `ERR_MODULE_NOT_FOUND` |
| Relative import from a builtin | `ERR_INVALID_MODULE_SPECIFIER` |
| Unsupported scheme (`http:`, `data:`) | `ERR_UNSUPPORTED_ESM_URL_SCHEME` |
| Syntax error in a module | QuickJS `SyntaxError`, filename and line preserved |

---

## 5. Event loop and async model

### 5.1 Current loop

`EventLoop.run` computes the next timer deadline, `zio.sleep`s until it, fires
due timers, and drains QuickJS jobs. It has no way to be woken by I/O.

### 5.2 New loop

Add a completion channel and multiplex it with the timer deadline:

```zig
var completions: zio.Channel(*Job) = .init(&buffer); // 256 slots

pub fn run(self: *EventLoop) !void {
    while (!self.stopped) {
        try self.drainJobs();
        try self.checkLimits();

        const deadline = self.nextDeadline();
        if (deadline == null and self.ref_count == 0) break;

        var recv = self.completions.asyncReceive();
        const timer: zio.Timeout = if (deadline) |ns|
            .fromNanoseconds(ns)
        else
            .none;

        const result = try zio.select(.{ .timer = &timer, .completion = &recv });
        switch (result) {
            .completion => |job| try self.dispatch(job),
            .timer => try self.fireDue(now()),
        }
        self.iterations += 1;
    }
}
```

Notes:

- `zio.Timeout` implements the select future protocol with a `WaitContext`, and
  `.none` means "never", so the same code handles timer-only, I/O-only, and
  mixed states.
- `Channel.asyncReceive()` is single-shot; create a new one each iteration.
  `select` cancels the losing arm itself.
- `ref_count` is the Node-style "keeps the process alive" counter. Pending fs
  and child process operations increment it; timers do not (the deadline
  handles them); a listening `http.Server` increments it until `close()`.
- `dispatch` runs on the JS task, so it may allocate and settle QuickJS values.

The loop runs inside `jsMain`, so `zio.select` and `Timeout` always have a task
context. If a specific zio version rejects `Timeout` arms there, the fallback is
a poll loop: `zio.sleep` until the next deadline and `Channel.tryReceive` for
completions. It is less efficient but structurally identical and can be swapped
without touching the job protocol.

`JoinHandle.join()` is the documented way to drive the executor from `main`, so
`Runtime.runMain` needs no custom event-loop driving code.

### 5.3 Job protocol

```zig
pub const Job = struct {
    kind: Kind,
    result: Result,
    resolve: quickjs.Value,
    reject: quickjs.Value,
};

pub const Result = union(enum) {
    ok,
    bytes: []u8,          // owned by the JS task after dispatch
    stat: FileStat,
    entries: []DirEntry,
    err: ErrorCode,
};
```

Rules:

- The I/O task allocates the `Job` and any payload with the host allocator.
- The job carries the QuickJS capability's `resolve`/`reject` values but never
  reads or writes them. Ownership transfers to the JS task. The capability is
  created on the JS task with `quickjs.Value.initPromiseCapability(ctx)`.
- After dispatch, the JS task deinits all values and frees the job and payload.
- On shutdown, the loop drains the channel, rejects remaining promises with
  `ERR_JSZ_SHUTDOWN` (an internal code), and frees every job.
- A `CompletionQueue` is a valid alternative if channel traffic ever becomes a
  bottleneck; the message shape stays the same.

### 5.4 Async-only fs

Every fs entry point shares one core, and that core always runs off the JS task:

```zig
fn readFileCore(host: *Host, path: []const u8, max: usize) ![]u8
fn readFile(...) quickjs.Value          // spawns a task that calls core, sends a Job
fn readFileSync(...) quickjs.Value      // always throws ERR_METHOD_NOT_IMPLEMENTED
```

The core is plain Zig over `std.Io.Dir`, written as if it were blocking. It only
ever executes inside a zio I/O task, where those calls suspend that task rather
than the JS task. The result travels through the completion channel and the JS
promise is settled when the loop dispatches the job.

The JS wrappers still expose the `*Sync` names so failures are explicit instead
of a `TypeError: not a function`. They throw `ERR_METHOD_NOT_IMPLEMENTED` with a
message naming the async alternative. `existsSync` cannot be expressed
asynchronously and is left out of the namespace entirely.

### 5.5 Timers and microtasks

Keep the existing rules:

- drain QuickJS jobs after every callback, promise settlement, and job dispatch;
- `sleep(ms)` keeps using a timer and a promise capability;
- interval re-arming keeps `deadline = now + interval` (no drift compensation,
  matching the current behavior).

Add:

- `process.nextTick(cb, ...args)` maps to `queueMicrotask`. Node runs nextTick
  before promise microtasks; QuickJS's job queue does not expose that split.
  Document the ordering difference.
- Unhandled rejections are still not reported. With `fs.promises` this becomes
  more visible; track it as a follow-up (§11).

### 5.6 Lifecycle and `process.exit`

- `process.exit(code)` sets `loop.exit_code`, marks the loop stopped, and
  cancels outstanding work. The CLI flushes stdout, deinits the runtime, then
  returns the code from `main`.
- Do not call `std.process.exit` before deinit: buffered stdout and QuickJS
  cleanup would be skipped.
- SIGINT: install `zio.Signal.init(.interrupt)` and, when it fires, run `process`
  `SIGINT` listeners if any; otherwise exit with code 130.
- On normal loop exhaustion (no timers, no refs, no pending jobs), return
  success.

---

## 6. Host integration

### 6.1 `Host` additions

```zig
pub const Host = struct {
    allocator: std.mem.Allocator,
    ctx: *quickjs.Context,
    loop: *EventLoop,
    out: *std.ArrayList(u8),
    io: std.Io,                      // zio_rt.io()
    argv: []const []const u8,        // process.argv
    environ: *std.process.Environ.Map,
    cwd: []const u8,                 // absolute, refreshed on chdir
    module: *ModuleRegistry,
    completions: *zio.Channel(*Job),
    exit_code: u8 = 0,
};
```

`Runtime.Options` grows `argv`, `environ_map`, and `cwd` (all optional so
tests can use defaults). `src/cli/cli.zig` must split argv at the script path
and pass the remainder through, so `process.argv` is correct:

```text
jsz script.js a b   ->  ["/path/to/jsz", "/abs/script.js", "a", "b"]
jsz -e "..." a b    ->  ["/path/to/jsz", "a", "b"]          (matches Node)
jsz -e "..."        ->  ["/path/to/jsz"]
```

`process.argv[1]` is always the absolute resolved script path for file
execution, matching Node.

### 6.2 Error mapping

All native failures become Node-shaped errors:

```js
const err = new Error("ENOENT: no such file or directory, open '/x'");
err.code = "ENOENT";
err.errno = -2;
err.syscall = "open";
err.path = "/x";
```

`src/js/errors.zig` owns a table from Zig errors to `{ code, errno, message }`:

| Zig error | Node code |
| --- | --- |
| `FileNotFound` | `ENOENT` |
| `AccessDenied`, `PermissionDenied` | `EACCES` |
| `PathAlreadyExists` | `EEXIST` |
| `NotDir` | `ENOTDIR` |
| `IsDir` | `EISDIR` |
| `DirNotEmpty` | `ENOTEMPTY` |
| `NameTooLong` | `ENAMETOOLONG` |
| `SymLinkLoop` | `ELOOP` |
| `NoSpaceLeft` | `ENOSPC` |
| `ReadOnlyFileSystem` | `EROFS` |
| `FileBusy` | `EBUSY` |
| `ProcessFdQuotaExceeded` | `EMFILE` |
| `SystemFdQuotaExceeded` | `ENFILE` |
| anything else | `EIO` |

`errno` numeric values are platform-dependent. Read them from `std.posix.E`
(its shape is OS-specific; a small per-OS helper is fine) and use `-1` on
Windows. Tests assert `code` and `syscall`, not `errno`.

### 6.3 Buffer strategy

`Buffer` is a JS `class Buffer extends Uint8Array` in `buffer.js`:

- `Buffer.from`, `Buffer.alloc`, `Buffer.allocUnsafe`, `Buffer.concat`,
  `Buffer.isBuffer`, `Buffer.byteLength`, `Buffer.compare`.
- Instance `toString`, `slice`, `subarray`, `equals`, `includes`, `indexOf`,
  `copy`, `fill`, `write`, and the fixed-width `readUInt*`/`writeUInt*` helpers
  implemented over `DataView`.
- Encodings: `utf8`, `utf-8`, `hex`, `base64`, `base64url`, `latin1`,
  `binary`, `ascii`, `utf16le`, `ucs2`.
- `Buffer.poolSize` exists but pooling is not implemented; `allocUnsafe` is a
  plain `Uint8Array`.

Risk: QuickJS must support subclassing `Uint8Array` and preserving the
species/prototype. Phase 1 includes a spike; if it fails, `Buffer` becomes a
plain class wrapping a `Uint8Array`, and `Buffer.isBuffer` still works, but
`instanceof Uint8Array` would no longer hold. That deviation must be
documented if it happens.

Encoding primitives live in `node:_encoding`, implemented with:

- QuickJS `JS_ToCStringLen` / `JS_NewStringLen` for UTF-8 conversion
  (`std.unicode.utf8ValidateSlice` for validation),
- `std.base64.standard` / `std.base64.url_safe_no_pad` encoders and decoders,
- `std.fmt.bytesToHex` and a nibble decoder,
- trivial `latin1` and `utf16le` conversions.

`TextEncoder` / `TextDecoder` are JS wrappers over the same native functions.
`TextDecoder` supports `utf-8`, `utf-16le`, `latin1`, and `fatal`/`ignoreBOM`
options; other labels throw `RangeError`.

### 6.4 Value marshalling

`src/js/value.zig` centralizes:

- `toSlice(ctx, value) []u8` for Buffer/TypedArray/ArrayBuffer/string,
- `fromBytes(ctx, bytes) Buffer` (calls into the JS `Buffer.from` once at
  startup and caches the function),
- `fromUtf8(ctx, bytes) string`,
- `getStringProp`, `getIntProp`, `getBoolProp`,
- `setStringProp` for building result objects,
- `callFunction(ctx, fn, this, args)` with exception propagation.

No native module builds JS objects inline; all object shapes are defined in the
JS wrappers and native modules return plain data. Exceptions: `Stats` and
`Dirent` are constructed natively because they are hot and numerous, but their
classes are registered from JS at startup to keep one definition.

---

## 7. Per-module design

### 7.1 `node:path` (pure JS)

Surface: `resolve`, `join`, `normalize`, `dirname`, `basename`, `extname`,
`relative`, `isAbsolute`, `parse`, `format`, `sep`, `delimiter`,
`toNamespacedPath`, plus `path.posix` and `path.win32`.

Implementation notes:

- `path.posix` is the default on POSIX; `path.win32` is always available.
- `resolve` needs `process.cwd()`; get it from the host at call time, not at
  module init, so `chdir` is reflected.
- Do not use `std.fs.path` in JS land: Node's normalization rules (double
  slashes, `.`/`..`, trailing slash preservation in `basename`) are specific
  and easier to match in JS.
- `path.win32` is pure string logic; no Windows host needed.

### 7.2 `node:fs` and `node:fs/promises` (native + JS, async only)

Layering:

```text
fs.js            option parsing, encoding, callbacks, Stats/Dirent classes
fs_promises.js   same core, promise-returning
node:_fs         syscalls in an I/O task, returns raw data/errno
```

`node:_fs` is plain Zig over `std.Io.Dir`. Every entry point runs inside a zio
I/O task; nothing here executes on the JS task.

Surface: callback and promise forms only. No `*Sync` API is implemented.

| Category | APIs |
| --- | --- |
| Read/write | `readFile`, `writeFile`, `appendFile`, `truncate` |
| Copy/move | `copyFile`, `cp` (recursive), `rename` |
| Remove | `rm`, `rmdir`, `unlink` |
| Directories | `mkdir` (recursive), `mkdtemp`, `readdir` (`withFileTypes`), `opendir` (deferred) |
| Metadata | `stat`, `lstat`, `fstat`, `access`, `realpath` |
| Permissions | `chmod`, `chown` (POSIX), `utimes` |
| Links | `symlink`, `readlink`, `link` |
| Descriptors | `open`, `close`, `read`, `write`, `fsync` |
| Constants | `F_OK`, `R_OK`, `W_OK`, `X_OK`, `O_*`, `COPYFILE_EXCL` |

Implementation per call:

- **Callback**: call the promise implementation and schedule the callback with
  `queueMicrotask` so it never runs synchronously (Node guarantees async
  callbacks).
- **Promise**: call the native async entry, which spawns a zio task and returns
  a QuickJS promise capability.
- **Sync names**: `readFileSync`, `statSync`, and every other `*Sync` wrapper
  exist only to throw `ERR_METHOD_NOT_IMPLEMENTED`. They never reach `node:_fs`.

Details:

- `readFile` encoding: `utf8` default for string results, `buffer`/`null` for
  `Buffer`. Reject unknown encodings with `ERR_INVALID_ARG_VALUE`.
- `writeFile` accepts `string`, `Buffer`, `TypedArray`, `DataView`. Options:
  `encoding`, `mode`, `flag` (`w`, `wx`, `a`, `ax`, `r+`, ...). Map flags to
  `CreateFileOptions{ .read, .truncate, .exclusive }`; unsupported flags throw.
- `stat` maps `std.Io.File.Stat`:
  - `size`, `ino`, `nlink`,
  - `mode` = type bits derived from `kind` OR'd with `permissions`,
  - `mtimeMs = stat.mtime.toMilliseconds()`, same for `atime`/`ctime`,
  - `birthtime` = `ctime` on platforms without a birth time,
  - `isFile()`, `isDirectory()`, `isSymbolicLink()`, `isFIFO()`, `isSocket()`.
- `readdir` uses `std.Io.Dir.iterate()`; `Dirent.name` is a JS string,
  `isDirectory()`/`isFile()`/`isSymbolicLink()` come from `DirEntry.kind`.
  `readdir` with `recursive: true` is a later addition; `cp` implements its own
  recursion.
- `mkdir({ recursive: true })` uses `createDirPath`; without it, `createDir`
  and translate `PathAlreadyExists` to `EEXIST`.
- `rm({ recursive, force })` uses `deleteTree` for directories and `deleteFile`
  for files; `force` swallows `ENOENT`.
- `realpath` uses `realPathFileAlloc`; `realpath.native` is the same function.
- `mkdtemp` uses `zio.createTempDir(.{ .prefix = prefix })`; the returned
  `zio.TempDir.name()` is the basename, and `os.tmpdir()` stays the parent.
- `cp` is implemented in Zig as a recursive walk (readdir + copyFile), because
  `std.Io.Dir.copyFile` is single-file only. Preserve mode bits where cheap;
  do not implement `preserveTimestamps` in v1.
- `utimes` maps to `Dir.setTimestamps(io, path, .{ .access_timestamp =
  .init(atime), .modify_timestamp = .init(mtime) })`; `.init(null)` maps to
  `.unchanged`.
- `link` maps to `Dir.hardLink(old_dir, old, new_dir, new, io, .{})`.
- `fs.watch`, `createReadStream`, `createWriteStream` are deferred; they throw
  `ERR_METHOD_NOT_IMPLEMENTED` with a clear message.
- `*Sync` entry points throw `ERR_METHOD_NOT_IMPLEMENTED`; `existsSync` is not
  exported at all. This is the largest intentional deviation from Node (§11).

FD-based operations: `std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } }`
can be constructed, so `read(fd, buffer, ...)` works by wrapping the descriptor
inside the I/O task. `open` returns an integer fd from `File.handle`. Closing
must not close stdio descriptors; track fds opened by us in the JS wrapper.

### 7.3 `node:process` (native + JS)

Implementation: `process.js` builds the object, `node:_process` supplies the
data.

| API | Source |
| --- | --- |
| `argv` | `Runtime.Options.argv` |
| `execArgv` | `[]` |
| `execPath` | `argv[0]` resolved to an absolute path (no std self-exe API; use `/proc/self/exe`, `_NSGetExecutablePath`, or argv[0] + PATH) |
| `env` | Proxy over `std.process.Environ.Map` |
| `cwd()` | `std.process.currentPathAlloc` |
| `chdir(path)` | `std.process.setCurrentPath(io, path)`; update `host.cwd` |
| `exit(code)` | loop stop + exit code (§5.6) |
| `pid`, `ppid` | `std.c.getpid()` / `std.c.getppid()` |
| `platform` | `@tagName(builtin.os.tag)` mapped to Node names |
| `arch` | `@tagName(builtin.cpu.arch)` mapped to Node names |
| `version` | jsz version with a Node-compatible prefix (documented) |
| `versions` | `{ jsz, zig, quickjs, zio }` |
| `hrtime()` / `hrtime.bigint()` | `zio.now()` |
| `uptime()` | `(now - started_at) / 1e9` |
| `memoryUsage()` | `std.posix.getrusage` where available, zeros otherwise |
| `nextTick()` | `queueMicrotask` |
| `stdout` / `stderr` | `{ write(chunk), isTTY, columns }` over the shared writer |
| `stdin` | deferred with `readline` |
| `on('exit' / 'SIGINT' / 'uncaughtException')` | `events` + `zio.Signal` |
| `emitWarning()` | `console.error` with `Warning:` prefix |
| `title` | settable string, no OS effect |
| `umask()` | `std.c.umask`, get/set |

`process.env` is a `Proxy`:

- `get` reads the environ map,
- `set`/`deleteProperty` mutate it and update the real environment when
  `std.process.Environ.Map` supports it (it owns the strings; verify mutation
  semantics in Phase 3),
- unknown keys return `undefined`, not `""`.

Do not snapshot the environment at startup: `process.env.FOO = "1"` followed by
`child_process.spawn` should pass `FOO` to the child.

### 7.4 `node:child_process` (native + JS)

Phasing:

1. `spawnSync`, `execSync`, `execFileSync`.
2. `spawn`, `exec`, `execFile` with callbacks and `ChildProcess` events.
3. `fork` is not in scope (needs a Node-compatible IPC channel).

`spawnSync`:

- `std.process.spawn(io, .{ .argv, .cwd, .environ_map, .stdin, .stdout = .pipe, .stderr = .pipe })`,
  then drain both pipes through `Io.File.MultiReader` (as `std.process.run`
  does internally) so neither can fill and deadlock.
- Write `input` to `child.stdin` (if any) and close it before draining.
- `child.wait(io)` after the pipes reach EOF; return `{ pid, status, signal,
  stdout, stderr, error }` with Buffers when `encoding` is `buffer`, strings
  otherwise.
- `execSync` runs through `/bin/sh -c` (POSIX) or `cmd /c` (Windows) and throws
  an Error with `status`, `signal`, `stdout`, `stderr` on non-zero exit.
- `exec`/`execFile` can use `std.process.run(gpa, io, .{ ... })` directly
  because the callback does not need the pid.
- `execSync` runs through `/bin/sh -c` (POSIX) or `cmd /c` (Windows) and throws
  an Error with `status`, `signal`, `stdout`, `stderr` on non-zero exit.

`spawn`:

- Spawn on a dedicated zio task.
- Attach `stdout`/`stderr` as minimal event emitters with `data` and `end`;
  no `pipe`, no backpressure, no `pause`/`resume`.
- Read each pipe in its own task because both can fill and deadlock if read
  sequentially.
- When both readers finish, `wait(io)` and send a completion with
  `{ code, signal }`; the JS task emits `exit` then `close`.
- `ChildProcess.kill()` calls `Child.kill(io)`, which sends `SIGTERM` and waits
  for the child to exit (zio's `process.childKill`). Node's signal argument is
  parsed; `SIGTERM` is the only supported value, others throw
  `ERR_FEATURE_UNAVAILABLE_ON_PLATFORM` until raw `kill(2)` is added.
- `stdin` is writable: `child.stdin.write()` writes to `File` and `end()`
  closes it. This is a small, non-streaming facade over `std.Io.File.Writer`.

`exec`/`execFile` collect output up to `maxBuffer` (default 1 MiB) and invoke
the callback with `(error, stdout, stderr)`.

Events: `spawn`, `exit`, `close`, `error`, plus `data`/`end` on the two output
facades. Everything else is deferred with the stream work.

### 7.5 `node:url` and WHATWG `URL`

- `URL` and `URLSearchParams`: pure JS in `url.js`, implementing the WHATWG
  basic URL parser for `http:`, `https:`, `ws:`, `wss:`, `file:`, and `data:`.
  Cover: scheme/host/port/path/query/hash, `origin`, `username`/`password`,
  `searchParams` live view, `toString`/`toJSON`, `href` setter,
  `URL.canParse`, `URL.parse`, and percent-encoding sets.
- `node:_url` provides `pathToFileURL(path)` and `fileURLToPath(url)`, because
  those need `std.fs.path.resolveAlloc` and `isAbsolute`.
- `URLSearchParams` supports `append`, `delete`, `get`, `getAll`, `has`,
  `set`, `sort`, `toString`, `forEach`, iteration, and the
  `application/x-www-form-urlencoded` serializer.
- `url.parse`, `url.format`, `url.resolve` (legacy) are not implemented; they
  are deprecated in Node and not part of the 90%.
- `domainToASCII`/`domainToUnicode` are not implemented (punycode).

Using `std.Uri` for `URL` was considered and rejected: `std.Uri` is an RFC 3986
parser, while `URL` must apply WHATWG normalization (host lowercasing, default
port elision, path dot-segment handling, encoded-set rules). A JS implementation
is smaller than a C boundary that fixes up `std.Uri` output.

### 7.6 `node:http` + global `fetch`

#### `http.createServer`

```js
import { createServer } from 'node:http';
const server = createServer((req, res) => {
  res.writeHead(200, { 'content-type': 'text/plain' });
  res.end('ok');
});
server.listen(3000, '127.0.0.1', () => {});
```

Native flow:

1. `listen(port, host, cb)` spawns an accept task:
   ```zig
   const addr = try std.Io.net.IpAddress.resolve(io, host, port);
   var server = try addr.listen(io, .{ .reuse_address = true });
   defer server.deinit(io);
   while (!closed) {
       const stream = try server.accept(io);
       _ = try connections.spawn(handleConnection, .{ stream, host });
   }
   ```
2. `handleConnection` builds `var reader = stream.reader(io, &rbuf);`
   `var writer = stream.writer(io, &wbuf);`
   `var http_server = std.http.Server.init(&reader.interface, &writer.interface);`
   `var request = try http_server.receiveHead();`
3. Read the body into a buffer using
   `request.readerExpectContinue(&body_buf)` when `request.head.expect != null`,
   otherwise `request.readerExpectNone(&body_buf)`, then `allocRemaining`, with a
   cap (default 1 MiB) to avoid unbounded memory.
4. Send a `RequestJob` to the JS task. The job carries method, target,
   HTTP version, headers, body, and a `*ResponseSlot`.
5. The JS task builds `IncomingMessage` and `ServerResponse`, calls the handler,
   and drains jobs (so a synchronous `res.end` completes immediately).
6. `ResponseSlot` holds status, headers, body buffer, and a `zio.Event` that
   the connection task waits on. If the handler ends later (timer, promise),
   the connection task parks on the event; `res.end` sets it.
7. The connection task calls
   `request.respond(body, .{ .status = status, .extra_headers = headers, .keep_alive = keep_alive })`
   and loops for the next request on the same connection until the client
   closes or `server.close()` runs.

`IncomingMessage` (minimal):

- `method`, `url`, `httpVersion`, `headers`, `rawHeaders`,
  `socket.remoteAddress`/`remotePort`, `complete`.
- `on('data')`/`on('end')`: replay the buffered body in one `data` event via
  `queueMicrotask`, then `end`. This is deliberately not a stream; document it.
- `setEncoding()` is accepted and affects the replayed chunks.

`ServerResponse` (minimal):

- `statusCode`, `statusMessage`, `headersSent`, `setHeader`, `getHeader`,
  `getHeaders`, `removeHeader`, `writeHead`, `write`, `end`, `flushHeaders`.
- `write` appends to a buffer; `end` finalizes and signals the slot.
- `res.on('finish')` fires after the response is handed to the connection task.

`server`:

- EventEmitter with `listen`, `close`, `address`, `listening`,
  `setTimeout` (no-op), `ref`/`unref` (adjust `loop.ref_count`).
- `listen({ port, host, backlog })`, `listen(port, cb)`, `listen(port, host, cb)`.
- `address()` returns `{ address, family, port }`; for port 0, read the bound
  port from `server.socket.address`.
- `close(cb)` stops accepting, waits for open connections (with a short grace
  period), then calls back.

Not implemented: `http.request`/`http.get`, upgrade/WebSocket, chunked request
streaming, trailers, `Expect: 100-continue` beyond std's handling, and
`https.createServer`.

#### `fetch`

```js
const res = await fetch('https://example.com/x', { method: 'POST', headers, body });
const text = await res.text();
```

Native flow (`node:_http`):

1. Parse the input with `std.Uri.parse`. Reject non-`http`/`https` schemes with
   `TypeError: Failed to parse URL`.
2. Create one `std.http.Client{ .allocator = host.allocator, .io = host.io }`
   per runtime and reuse it. Each `fetch` runs the whole request in a zio child
   task (connect, send, receive head, read body) and sends a `Job` back; the
   task touches no QuickJS values. `Client.request` is documented threadsafe,
   and keeping one shared client lets its pool reuse connections.
   `std.http.Client` loads and rescans the system CA bundle itself, so HTTPS
   works without configuration.
3. `client.request(method, uri, .{ .extra_headers = headers, .redirect_behavior = .init(5) })`,
   then `req.sendBodyComplete(body)` (or `sendBodiless`), then
   `const response = try req.receiveHead(&head_buffer);`.
4. Read the body with `response.reader(&transfer_buffer).allocRemaining(...)`,
   capped (default 10 MiB; `Content-Length` is an early reject if larger).
5. Build the JS `Response` with `response.head.status`, `reason`, `ok`, `url`,
   `redirected`, `headers`, and a `Buffer` body.

JS facade:

- `Headers` with case-insensitive `get`/`set`/`has`/`append`/`delete`,
  `forEach`, and iteration.
- `Response` with `text()`, `json()`, `arrayBuffer()`, `bytes()`, `clone()`
  (body copy), `bodyUsed`.
- `Request` is accepted as a plain options object; a `Request` class is not
  required by the 90% set.
- `AbortSignal`: a minimal `AbortController` exists, but it only prevents a
  request from starting and rejects after completion. In-flight cancellation is
  deferred because `std.http.Client` exposes no cancellation handle.
- Redirects: follow up to 5 for 301/302/303/307/308, matching `fetch` defaults.
- `credentials`, `mode`, `cache`, `integrity` are parsed and ignored.

### 7.7 `node:crypto` (native + JS)

| API | Implementation |
| --- | --- |
| `createHash(alg)` | JS accumulator + `node:_crypto.hash(alg, bytes)` one-shot |
| `createHmac(alg, key)` | JS accumulator + `node:_crypto.hmac(alg, key, bytes)` |
| `randomBytes(n[, cb])` | `std.Io.randomSecure(io, buf)` |
| `randomUUID()` | v4 UUID from 16 secure bytes |
| `randomInt([min,] max[, cb])` | rejection sampling over secure bytes |
| `getRandomValues(typedArray)` | secure bytes, in place |
| `timingSafeEqual` | deferred (last 10%) |
| `pbkdf2Sync`, `scryptSync` | stretch: `std.crypto.pwhash` |
| `createCipheriv`, `generateKeyPair`, `sign`/`verify` | deferred |
| `webcrypto.subtle` | deferred |

Hash names and Zig types:

| Node name | Zig |
| --- | --- |
| `md5` | `std.crypto.hash.Md5` |
| `sha1` | `std.crypto.hash.Sha1` |
| `sha256` | `std.crypto.hash.sha2.Sha256` |
| `sha384` | `std.crypto.hash.sha2.Sha384` |
| `sha512` | `std.crypto.hash.sha2.Sha512` |
| `sha512-256` | `std.crypto.hash.sha2.Sha512_256` |
| unknown | `ERR_CRYPTO_HASH_UNKNOWN` |

`createHash`/`createHmac` accumulate in JS because Zig's hash state cannot be
owned safely across the C boundary without a native finalizer. The cost is one
copy of the input, which is acceptable for the 90% set. If profiling shows a
problem, add a native context object with a QuickJS class finalizer later.

`digest(encoding)` returns a Buffer by default; `digest('hex')` and
`digest('base64')` use the same encoders as Buffer.

`crypto.webcrypto` exists as an object with `getRandomValues` only; `subtle`
throws `ERR_METHOD_NOT_IMPLEMENTED`.

### 7.8 `node:util` (pure JS)

- `format(fmt, ...args)` with `%s`, `%d`, `%i`, `%f`, `%j`, `%o`, `%O`, `%c`,
  `%%`.
- `inspect(value, opts)`: depth-limited, cycle-safe printer. Cover strings,
  numbers, bigint, boolean, null/undefined, arrays, plain objects, Map, Set,
  Date, RegExp, Error, Buffer, functions, and class names. Options: `depth`,
  `colors` (ignored but accepted), `compact`, `sorted`, `maxArrayLength`,
  `breakLength`, `showHidden`.
- `types`: `isDate`, `isRegExp`, `isPromise`, `isTypedArray`, `isUint8Array`,
  `isArrayBuffer`, `isMap`, `isSet`, `isNativeError`.
- `promisify(fn)` and `promisify.custom`.
- `callbackify(fn)`.
- `inherits(ctor, superCtor)`.
- `deprecate(fn, msg)`.
- `isDeepStrictEqual(a, b)`.
- `parseArgs` (stretch).
- `TextEncoder`/`TextDecoder` re-exports.

`inspect` is the highest-risk item in this module. A compact but predictable
implementation is enough; it is not required to match Node byte-for-byte.
Fixtures should assert structure, not exact spacing, except for a few golden
cases.

### 7.9 `node:events` (pure JS)

`EventEmitter` with:

- `on`, `addListener`, `prependListener`, `once`, `prependOnceListener`,
- `off`, `removeListener`, `removeAllListeners`,
- `emit`, `listeners`, `rawListeners`, `listenerCount`, `eventNames`,
- `setMaxListeners`, `getMaxListeners`,
- `events.once(emitter, name)` and `events.on(emitter, name)` async iterators
  (the latter is a stretch; `once` is required).

Semantics:

- `emit('error')` with no listener throws the error.
- `once` wrappers are removable by the original listener.
- Listeners are called in registration order with `this = emitter`.
- Adding a listener during `emit` does not affect the current emit.
- `newListener`/`removeListener` meta events.

This module is shared by `http`, `child_process`, `process`, and the minimal
output facades. It must be loaded before them (module init order is handled by
ESM imports).

### 7.10 `node:os` (native + JS)

| API | Source |
| --- | --- |
| `platform()`, `arch()`, `type()` | `builtin.os.tag` / `builtin.cpu.arch` |
| `release()` | `std.posix.uname().release` |
| `version()` | `std.posix.uname().version` |
| `hostname()` | `std.posix.gethostname` |
| `homedir()` | `HOME` / `USERPROFILE`, fallback `/` |
| `tmpdir()` | `TMPDIR` / `TEMP` / `/tmp` |
| `EOL` | `"\n"` or `"\r\n"` |
| `devNull` | `/dev/null` or `NUL` |
| `cpus()` | `std.Thread.getCpuCount()`, synthetic per-core objects |
| `availableParallelism()` | `std.Thread.getCpuCount()` |
| `totalmem()`, `freemem()` | stretch: libc `sysctl`/`sysinfo` |
| `uptime()` | `std.Io.Timestamp.now(io, .boot).toSeconds()` |
| `loadavg()` | libc `getloadavg(3)` via `@cImport`/`std.c` (no std wrapper) |
| `userInfo()` | `getuid`/`getgid`, `USER`/`LOGNAME`, `SHELL` |
| `networkInterfaces()` | deferred (no std API) |
| `machine()` | `std.posix.uname().machine` |

`os.cpus()` returns `{ model: "unknown", speed: 0, times: { user: 0, nice: 0, sys: 0, idle: 0, irq: 0 } }`
per core. It is honest about not having per-core counters; the length is
correct, which is what most code uses.

### 7.11 `node:buffer` (pure JS + `node:_encoding`)

Re-exports `Buffer`, `SlowBuffer` (alias of `Buffer`), `INSPECT_MAX_BYTES`,
`kMaxLength`, and `atob`/`btoa`. See §6.3.

### 7.12 Globals

| Global | Implementation |
| --- | --- |
| `console` | existing, extend with `info`, `warn`, `error`, `debug`, `trace`, `dir`, `time`/`timeEnd` |
| `setTimeout`/`setInterval`/`clear*` | existing |
| `queueMicrotask` | QuickJS built-in |
| `process` | `node:process` namespace, installed as a global |
| `Buffer` | `node:buffer` |
| `URL`, `URLSearchParams` | `node:url` |
| `TextEncoder`, `TextDecoder` | `node:util` |
| `atob`, `btoa` | `node:buffer` |
| `fetch`, `Headers`, `Response` | `node:http` (fetch facade) |
| `AbortController`, `AbortSignal` | minimal JS |
| `structuredClone` | deferred |
| `performance` | `{ now(), timeOrigin }` over `zio.now()` |
| `crypto` | `{ getRandomValues }` |
| `globalThis.global` | `globalThis` (Node compat) |

Globals are installed at context creation from the same JS sources, not
duplicated in Zig. `builtins.register` keeps timers/console native and calls
into the JS bootstrap for the rest.

---

## 8. Required zio and Zig APIs

`zigdoc` cannot analyze the `zio` and `quickjs` imported modules under Zig
0.17 (`error: UnsupportedZigVersion`). `std` symbols were verified with
`zigdoc`; zio and QuickJS signatures below come from the vendored sources at
the pinned commits. Every symbol listed here should still be re-checked with
`zigdoc` once it supports 0.17, or by compiling a small probe.

### 8.1 zio runtime and tasks

| API | Used for |
| --- | --- |
| `zio.Runtime.init(allocator, .{ .executors = .exact(1) })` | single executor, single-threaded JS |
| `Runtime.deinit()` | shutdown |
| `Runtime.io() -> std.Io` | all `std.Io` syscalls |
| `Runtime.blockingIo() -> std.Io` | fallback for native-callback contexts |
| `Runtime.spawn(fn, args) -> JoinHandle(T)` | I/O tasks, connection tasks |
| `JoinHandle.join()` | drive the executor from `main`, run the main JS task |
| `JoinHandle.cancel()` | cancel outstanding work on exit |
| `zio.spawn` / `zio.spawnBlocking` | task-local spawn when a `*Runtime` is not handy |
| `zio.now() -> Timestamp` | timers, `hrtime`, `performance.now` |
| `zio.sleep(Duration)` | existing timer loop fallback |
| `RuntimeOptions.thread_pool` | blocking syscalls (`spawnBlocking`) |
| `RuntimeOptions.dns` | keep the built-in resolver on Linux; on macOS `getaddrinfo` |

`allocator` must be thread-safe: tasks allocate jobs from it. Use the process
GPA (`init.gpa`) or a thread-safe arena for jobs.

### 8.2 zio select, channels, sync

| API | Used for |
| --- | --- |
| `zio.select(.{ .timer = &timeout, .completion = &recv })` | event loop multiplexing |
| `zio.Timeout{ .deadline = ... }` / `.none` | timer arm; implements the future protocol |
| `zio.Channel(*Job).init(&buffer)` | completion queue |
| `Channel.send` / `Channel.trySend` | I/O task completion |
| `Channel.receive` / `asyncReceive` | loop dispatch |
| `Channel.close(.graceful)` | shutdown |
| `zio.CompletionQueue` | optional high-volume alternative |
| `zio.Event` (`.set` / `.wait`) | `res.end` handshake between JS task and connection task |
| `zio.Group` | track connections, child process readers, fetch tasks |
| `zio.Signal.init(.interrupt)` + `Signal.wait` | SIGINT |
| `zio.Cancelable` | propagate cancellation on exit |
| `zio.randomSecure(buf)` | crypto random bytes (alternative to `std.Io.randomSecure`) |

### 8.3 zio filesystem (only where `std.Io` has no equivalent)

| API | Used for |
| --- | --- |
| `zio.createTempDir(.{ .prefix = ... })` | `fs.mkdtemp` |
| `zio.TempDir.name()` / `.deinit()` | temp dir result and cleanup |
| `zio.createTempFile(options)` | optional |
| `zio.Dir.iterate()` | not needed if `std.Io.Dir.iterate` is used |
| `zio.File.size()` / `.stat()` | `fstat` if `std.Io.File.stat` is insufficient |
| `zio.os.fs.FileStatInfo` | fallback stat shape (`atime`, `mtime`, `ctime` ns) |
| `zio.os.fs.DirEntry` | fallback directory entry (`name`, `kind`, `inode`) |

Prefer `std.Io.Dir` for everything it covers; it is already zio-backed.

### 8.4 Zig std filesystem (`std.Io.Dir` / `std.Io.File`)

These calls execute inside a zio I/O task; the JS task never calls them
directly.

| API | Used for |
| --- | --- |
| `std.Io.Dir.cwd()` | base directory |
| `Dir.openFile(io, path, .{ .mode = .read_only })` | `open`, `readFile` |
| `Dir.createFile(io, path, .{ .read, .truncate, .exclusive })` | `writeFile`, `appendFile`, `open` |
| `Dir.createDir(io, path, permissions)` | `mkdir` |
| `Dir.createDirPath(io, path)` | `mkdir({ recursive: true })` |
| `Dir.deleteFile(io, path)` | `unlink` |
| `Dir.deleteDir(io, path)` | `rmdir` |
| `Dir.deleteTree(io, path)` | `rm({ recursive: true })`, `cp` overwrite |
| `Dir.rename(old_dir, old, new_dir, new, io)` | `rename` |
| `Dir.statFile(io, path, .{ .follow_symlinks })` | `stat`, `lstat` |
| `Dir.access(io, path, .{ .read, .write, .execute })` | `access` |
| `Dir.realPathFileAlloc(io, path, allocator)` | `realpath` |
| `Dir.readFileAllocOptions(io, path, alloc, .limited(n), .of(u8), 0)` | `readFile` worker, module loading |
| `Dir.writeFile(io, .{ .sub_path, .data, .flags })` | `writeFile` |
| `Dir.copyFile(src_dir, src, dst_dir, dst, io, .{})` | `copyFile` |
| `Dir.symLink(io, target, link, .{})` | `symlink` |
| `Dir.hardLink(old_dir, old, new_dir, new, io, .{})` | `link` |
| `Dir.readLink(io, path, buffer)` | `readlink` |
| `Dir.openDir(io, path, .{ .iterate = true })` | `readdir` (cwd is not iterable) |
| `Dir.iterate()` + `Iterator.next(io)` | `readdir` entries |
| `Dir.setFilePermissions(io, path, mode, .{})` | `chmod` |
| `Dir.setFileOwner(io, path, uid, gid, .{})` | `chown` |
| `Dir.setTimestamps(io, path, .{ .access_timestamp, .modify_timestamp })` | `utimes` |
| `File.setLength(io, len)` | `truncate` |
| `File.reader(io, &buf)` + `Reader.interface.allocRemaining(alloc, .limited(n))` | read whole file |
| `File.writer(io, &buf)` + `Writer.interface.writeAll` | write / append |
| `File.reader` / `File.writer` positional vs streaming modes | fd reads/writes |
| `File.close(io)` | close |
| `File.stat(io)` | `fstat` |
| `File.setPermissions(io, mode)` | `fchmod` |
| `File.Stat{ inode, nlink, size, permissions, kind, atime, mtime, ctime }` | `Stats` |
| `File.Kind` (`file`, `directory`, `sym_link`, `named_pipe`, ...) | `Dirent` / `Stats` predicates |
| `Io.Timestamp.toMilliseconds()` | `mtimeMs`, `atimeMs`, `ctimeMs` |

Gaps in `std.Io` for fs:

- `truncate` on a path: deliberately no path-level API. Open with write and
  call `File.setLength(io, len)`.
- `watch`: no API; deferred.
- file locking: `CreateFileOptions.lock` exists, but Node's `fs` does not expose
  it directly; ignore.

### 8.5 Zig std process

| API | Used for |
| --- | --- |
| `std.process.Init.gpa` | allocator |
| `std.process.Init.environ_map` | `process.env` |
| `std.process.Init.minimal.args` | `process.argv` |
| `std.process.currentPathAlloc(io, alloc)` | `cwd()` |
| `argv[0]` + OS executable path (`/proc/self/exe`, `_NSGetExecutablePath`) | `execPath` (no std API) |
| `std.process.setCurrentPath(io, path)` | `chdir()` |
| `std.process.spawn(io, SpawnOptions)` | `spawn`, `spawnSync` |
| `std.process.run(gpa, io, RunOptions) -> RunResult` | `exec`/`execFile` collection |
| `Io.File.MultiReader` | concurrent stdout/stderr drain |
| `SpawnOptions{ exe, argv, cwd, environ_map, stdin, stdout, stderr }` | child configuration |
| `SpawnOptions.StdIo.pipe` / `.inherit` / `.ignore` | stdio wiring |
| `std.process.Child.stdin/stdout/stderr: ?File` | pipes |
| `Child.wait(io) -> Term` | exit code/signal |
| `Child.kill(io)` | `child.kill()` |
| `Term.exited/signal/stopped` | `exit` event |
| `std.process.Environ.Map.get/put/iterator` | env proxy |
| `std.c.getpid` / `std.c.getppid` (libc) | `process.pid`, `ppid` |
| `std.c.umask` (libc) | `process.umask` |
| `std.posix.getrusage` | `process.memoryUsage` (partial) |

Notes:

- `SpawnOptions.exe` defaults to `.detect`, which searches `PATH` using the
  parent environment. `execFile` should use `.detect` as well, matching Node.
- `std.process.spawn` over zio uses `processSpawnImpl`, which is implemented;
  process groups and `uid`/`gid` are passed through where the OS supports them.
- Signal sending beyond `kill` is a gap (see §8.8).

### 8.6 Zig std net and HTTP

| API | Used for |
| --- | --- |
| `std.Io.net.IpAddress.resolve(io, host, port)` | listen/connect address, hostnames included |
| `std.Io.net.IpAddress.parse(text, port)` | numeric-only fast path |
| `std.Io.net.IpAddress.listen(io, .{ .reuse_address = true })` | `http.Server.listen` |
| `std.Io.net.Server.accept(io)` | accept loop |
| `std.Io.net.Stream.reader(io, &buf)` / `.writer(io, &buf)` | HTTP connection streams |
| `Stream.close(io)` / `Stream.shutdown(io, .both)` | connection teardown |
| `std.http.Server.init(&reader.interface, &writer.interface)` | per-connection HTTP |
| `Server.receiveHead()` | parse request head |
| `Request.head` (`method`, `target`, `version`, `keep_alive`) | `req.method`, `req.url`, `req.httpVersion` |
| `Request.iterateHeaders()` | `req.headers`, `rawHeaders` |
| `Request.readerExpectNone(&buf)` / `readerExpectContinue(&buf)` | request body |
| `Request.respond(body, .{ .status, .reason, .keep_alive, .extra_headers })` | `res.end` |
| `std.http.Client{ .allocator, .io }` | `fetch` |
| `Client.request(method, uri, .{ .extra_headers, .redirect_behavior })` | request with headers (`RedirectBehavior.init(5)` for fetch) |
| `Client.deinit()` | release the pool and CA bundle at shutdown |
| `Request.sendBodiless()` / `sendBodyComplete(body)` | request body |
| `Request.receiveHead(&buf) -> Response` | response status + headers |
| `Response.reader(&buf)` + `allocRemaining` | response body |
| `Request.deinit()` | return connection to pool |
| `std.Uri.parse` | URL validation for `fetch` |
| `std.http.Method` / `std.http.Status` | method/status mapping |

Notes:

- `std.http.Client.fetch` is one-shot and returns only a status; we need
  `request` + `receiveHead` for headers and body, so use that path.
- `Client` auto-loads and rescans the system CA bundle (verified in
  `std/http/Client.zig`), so HTTPS needs no extra setup.
- `std.http.Server` has no TLS variant, hence no `https.createServer`.
- `Request.respond` buffers the whole body. `res.write` accumulates in JS and
  `res.end` performs a single respond. Large responses hold the full body in
  memory; document this limit.

### 8.7 Zig std crypto, encoding, OS, misc

| API | Used for |
| --- | --- |
| `std.crypto.hash.Md5` / `Sha1` / `sha2.Sha256` / `Sha384` / `Sha512` / `Sha512_256` | `createHash` |
| `std.crypto.auth.hmac.sha2.HmacSha256` / `HmacSha512` | `createHmac` |
| `std.crypto.timing_safe.eql` | `timingSafeEqual` (deferred) |
| `std.crypto.pwhash.pbkdf2` / `scrypt` | stretch |
| `std.Io.randomSecure(io, buf)` | `randomBytes`, `randomUUID`, `getRandomValues` |
| `std.base64.standard.Encoder/Decoder` | `base64` |
| `std.base64.url_safe_no_pad.Encoder/Decoder` | `base64url` |
| `std.fmt.bytesToHex` | `hex` encode |
| `JS_ToCStringLen` / `JS_NewStringLen` + `std.unicode.utf8ValidateSlice` | `utf8`, `TextEncoder`/`TextDecoder` |
| `std.unicode.utf16LeToUtf8Alloc` / `utf8ToUtf16LeAlloc` | `utf16le`/`ucs2` |
| `std.Thread.getCpuCount()` | `os.cpus().length`, `availableParallelism` |
| `std.posix.uname()` | `os.type/release/version/machine` |
| `std.posix.gethostname(&buf)` | `os.hostname()` |
| `std.posix.getrusage` | `process.memoryUsage` |
| `std.Io.Timestamp.now(io, .boot)` | `os.uptime()` (already ns since boot) |
| `extern fn getloadavg` (not in `std.c`) | `os.loadavg()` |
| `std.fs.path.resolveAlloc` / `isAbsolute` / `dirname` / `basename` | `pathToFileURL`, resolver |
| `std.Uri.parse` / `resolveInPlace` | URL/normalizer helpers |
| `builtin.os.tag`, `builtin.cpu.arch` | platform/arch |

### 8.8 Gaps: no zio or Zig std API

These need a local bridge or must be deferred. Each is listed with the proposed
workaround.

| Capability | Gap | Plan |
| --- | --- | --- |
| TLS server (`https.createServer`) | `std.crypto.tls` has a client only | deferred; `http.createServer` only |
| `fs.truncate` | no path-level truncate | open + `File.setLength(io, len)` |
| `fs.watch` | no API | deferred |
| `os.freemem`/`totalmem` | no portable API | libc `sysctl`/`sysinfo` per OS, or omit |
| `os.networkInterfaces` | no std API | deferred |
| `os.cpus()` per-core times | no std API | stubbed counters, correct length |
| `child_process` arbitrary signals | `Child.kill` only sends `SIGTERM` | POSIX `kill(2)` for known signals; else throw |
| `process.memoryUsage` exact rss/heap | QuickJS does not expose its allocator | `getrusage` for rss; heap fields report 0 |
| `fetch` in-flight abort | no `std.http` cancel handle | abort before start; document |
| QuickJS `*ModuleDef` extraction | wrapper gap | §4.5 |
| `Buffer` typed-array subclassing | must be verified in QuickJS | spike; fallback wrapper class |
| `TextDecoder` invalid UTF-8 | QuickJS string creation policy | test; substitute U+FFFD if needed |

---

## 9. Phases and milestones

Each phase is independently shippable and testable. Phases 3A and 3B can run in
parallel once Phase 2 lands.

### Phase 0 - Module foundation (blocker)

- Register `setModuleLoaderFunc` and `normalize`.
- Builtin registry with alias canonicalization.
- Embedded JS module loading (`@embedFile` + compile + import.meta).
- File resolver with extension/index probing and `file://` URLs.
- Entry mode detection (`.mjs`, `.cjs`, `.js`, `-e`).
- Solve `*ModuleDef` extraction (§4.5).
- Stub builtins (`path`, `util`, `events`) that exercise the loader.

Exit criteria:

- `import { join } from 'node:path'` and `import { join } from 'path'` resolve
  to the same module instance.
- Relative ESM imports work across at least three files with a cycle.
- `import.meta.url` and `import.meta.main` are correct.
- A `.js` file with top-level `export` is auto-detected as a module.
- `fs` is not required yet; the stub proves the pipeline.

### Phase 1 - Async core, encoding, Buffer

- `jobs.zig`: `Job`, channel, dispatch, shutdown drain.
- `EventLoop.run` uses `zio.select` over timer + completion.
- `ref_count` and `process.exit` plumbing.
- `node:_encoding` and `buffer.js`; TextEncoder/TextDecoder; atob/btoa.
- `Host` extension (`io`, `argv`, `environ`, `cwd`).
- Value marshalling helpers.

Exit criteria:

- A native `sleep`-like op completes through the channel and settles a promise.
- Buffer round-trips utf8/hex/base64/base64url/latin1/utf16le.
- `Buffer` subclassing verified; documented if it deviates.
- Loop exits when there are no timers, no refs, and no jobs.
- Leak tests with `std.testing.allocator` pass.

### Phase 2 - Filesystem

- `node:_fs` native core for all §7.2 APIs, always executed inside a zio I/O
  task.
- `fs.js` and `fs/promises.js` wrappers, callbacks, Stats, Dirent, constants.
- Every async entry spawns a task and settles a job; `*Sync` names throw
  `ERR_METHOD_NOT_IMPLEMENTED`.
- Error mapping and `syscall`/`path` fields.

Exit criteria:

- Fixtures cover read/write/append/copy/rename/rm/mkdir/readdir/stat/realpath.
- Callback `fs.readFile` and `await fs.promises.readFile` return identical bytes.
- A 10 MiB read does not block timers (test with a 10 ms interval and assert
  ticks fired).
- `fs.readFileSync` throws `ERR_METHOD_NOT_IMPLEMENTED` and `fs.existsSync` is
  `undefined`.
- `ENOENT` and `EEXIST` shapes match the table in §6.2.
- `chdir` is reflected in `process.cwd()` and relative fs paths.

### Phase 3A - process, os, crypto

- `node:_process`, `process.js`, `os.js`.
- `node:_crypto`, `crypto.js`.
- `process.exit`, SIGINT, exit hooks.
- `randomUUID`, `randomInt`, hash/HMAC one-shot.

Exit criteria:

- `process.argv` matches the CLI invocation, including script path.
- `process.env` mutation is visible to `child_process` (after Phase 4).
- `os.cpus().length > 0`, `os.homedir()` and `os.tmpdir()` exist.
- `createHash('sha256')` matches known vectors; `randomUUID` is v4.
- `process.exit(3)` exits with code 3 and flushes stdout.

### Phase 3B - path, url, util, events

- `path.js` (posix + win32) and fixtures.
- `url.js` (`URL`, `URLSearchParams`) + `node:_url` helpers.
- `util.js` (`format`, `inspect`, `types`, `promisify`, `callbackify`).
- `events.js`.

Exit criteria:

- Path fixtures match Node for a table of ~100 cases.
- `new URL('https://a/b?c#d').href` and `searchParams` mutations round-trip.
- `EventEmitter` semantics tests (once, remove, error, meta events).
- `util.inspect` handles cycles and depth limits without throwing.

### Phase 4 - child_process

- `spawnSync`, `execSync`, `execFileSync`.
- `spawn`, `exec`, `execFile`, minimal output facades.
- `kill`, `stdin.write/end`, `exit`/`close` events.

Exit criteria:

- `spawnSync('echo', ['hi'])` returns `hi\n` and status 0.
- Non-zero exit sets `status` and does not throw in `spawnSync`.
- `spawn` captures both stdout and stderr concurrently without deadlock.
- `execSync('exit 3')` throws with `status === 3`.
- Killing a long-running child emits `exit` with a signal.

### Phase 5 - HTTP server and fetch

- `node:_http` accept/connection tasks, request/response jobs.
- `http.js` server, `IncomingMessage`, `ServerResponse`.
- `fetch`, `Headers`, `Response`, minimal `AbortController`.
- `listen(0)` + `address()` correctness.

Exit criteria:

- A local server echoes a POST body; client sees status, headers, body.
- `listen(0)` reports the real port.
- `server.close()` releases the port and resolves the callback.
- `fetch` works against the local server and against one HTTPS URL in a manual
  (non-CI) test.
- Response body larger than the cap yields a clear error, not OOM.
- Timers continue to fire while an HTTP connection is open.

### Phase 6 - fidelity and hardening

- Error message table completion, `errno` values.
- Stats/Dirent fidelity, symlink behavior, `lstat`.
- Shutdown ordering, cancelled job rejection, leak audit.
- Docs: `docs/roadmap.md`, `docs/testing.md`, README compatibility table.
- Optional differential tests against Node when `node` is on `PATH`.

Exit criteria:

- The compatibility matrix in Appendix A is accurate.
- `mise run check` passes.
- No leaks under `std.testing.allocator` in the integration suite.
- Known deviations are documented, not implicit.

---

## 10. Testing strategy

- **Zig unit tests** for `module.zig` resolution, error mapping, job lifetime,
  and encoding.
- **JS fixtures** under `tests/fixtures/` for every module. Each fixture prints
  deterministic output; `fixtures_test.zig` asserts stdout and exit code.
- **Module fixtures** under `tests/fixtures/modules/` for relative imports,
  cycles, alias identity, `import.meta`, and missing-module errors.
- **Async fixtures** use `await sleep(ms)` and assert ordering, not wall-clock
  durations, except where a duration is the point (loop not blocked).
- **Leak tests** run each native entry with `std.testing.allocator` and assert
  no leaks, including error paths.
- **Sync-fs guard** fixtures assert that `fs.readFileSync` and friends throw
  `ERR_METHOD_NOT_IMPLEMENTED` and that `fs.existsSync` is undefined.
- **Differential tests** (optional, skipped when `node` is absent) compare
  `path` and encoding results against the local Node binary.
- **Manual HTTPS check** documented in `docs/testing.md`; CI runs offline with
  a local HTTP server only.

### 10.1 Porting Node.js's own tests into `tests/fixtures/`

For every module we implement, the primary behavioral reference is the official
Node.js test suite. We port selected cases from the `nodejs/node` repo into
`tests/fixtures/` so jsz has the same coverage ground truth, adapted to our
constraints (ESM-only, async-only `fs`, no `require`, no `test/common`).

Source repo (local partial clone):

```text
/private/var/folders/7b/3zt0gmk10ynfm5byf21zymnm0000gn/T/opencode/node-src
  remote: https://github.com/nodejs/node (main, partial clone)
  sparse checkout: test/common, test/parallel, test/sequential
```

To pull `test/fixtures` (needed by some tests for data files):

```sh
cd /private/var/folders/7b/3zt0gmk10ynfm5byf21zymnm0000gn/T/opencode/node-src
git sparse-checkout add test/fixtures
```

Local inventory as of writing: 397 `test-fs-*` tests across `test/parallel`
and `test/sequential` (read 80, write 52, watch 53, link 33, symlink 29,
readfile 20, rm 15, readdir 14, open 12, stat 12, close 11, realpath 8,
chmod/chown 11, mkdir 5, mkdtemp 5, plus filehandle/promises suites).

Porting rules:

- Select the highest-value cases per implemented API (happy path, error shape,
  option parsing, edge cases like empty files, long paths, UTF-8 names), not
  the entire suite.
- Convert CommonJS to ESM (`require`/`module.exports` to `import`/`export`).
- Drop `test/common` harness usage; replace with deterministic `console.log`
  output asserted by `tests/zig/*_test.zig` (or `assert`-style checks that
  exit non-zero on failure).
- Skip `*Sync`, streams, watchers, and fd-level tests when the corresponding
  API is not implemented or is an explicit `ERR_METHOD_NOT_IMPLEMENTED` stub.
- Keep one fixture per topic (e.g. `fs_readfile.js`, `fs_mkdir.js`,
  `util_format.js`), named after the Node tests they derive from, with a
  comment citing the original test file(s).
- Fixtures must clean up after themselves (temp files under
  `tests/fixtures/.<topic>-work/`, removed at the end).

Per-phase mapping (extend as each phase starts):

| Phase | Port from Node tests into `tests/fixtures/` |
| --- | --- |
| 2 - fs | `test-fs-readfile*`, `test-fs-writefile*`, `test-fs-append-file*`, `test-fs-mkdir*`, `test-fs-readdir*`, `test-fs-stat*`, `test-fs-realpath*`, `test-fs-copyfile*`, `test-fs-cp*`, `test-fs-rm*`, `test-fs-unlink*`, `test-fs-rename*`, `test-fs-symlink*`, `test-fs-link*`, `test-fs-chmod*`, `test-fs-chown*`, `test-fs-truncate*`, `test-fs-utimes*`, `test-fs-access*`, `test-fs-exists*` (callback + `fs/promises` variants; skip `*Sync`) |
| 3A - process/os/crypto | `test-process-*`, `test-os-*`, `test-crypto-hash*`, `test-crypto-hmac*`, `test-crypto-random*` (selected cases) |
| 3B - path/url/util/events | `test-path-*`, `test-url-*` (WHATWG), `test-util-*`, `test-events-*` (selected cases) |
| 4 - child_process | `test-child-process-exec*`, `test-child-process-spawn*` (selected cases) |
| 5 - http/fetch | `test-http-server-*`, `test-fetch-*` (selected, local server only) |

Test harness changes:

- `tests/zig/main.zig` adds `module_test.zig`, `fs_test.zig`, `encoding_test.zig`,
  `http_test.zig`.
- Fixture runner needs a way to pass argv and env for `process` tests.
- A fixture may import both `fs` and `node:fs` to assert identity.

---

## 11. Risks and open questions

| Risk | Impact | Mitigation |
| --- | --- | --- |
| `JS_VALUE_GET_PTR` not exposed by translate-c | blocks module loading | Phase 0 spike; fallback is a two-line wrapper fork; do not reimplement `JSValue` layout |
| Suspending the JS task inside a QuickJS C callback (module loader) | could corrupt state | only the JS task touches QuickJS; validate with a dynamic import from a timer callback in Phase 0 |
| `zio.select` rejects the `Timeout` arm | loop rewrite | fallback: `zio.sleep` + `Channel.tryReceive` poll loop |
| QuickJS `Uint8Array` subclassing | Buffer fidelity | Phase 1 spike; document wrapper-class fallback |
| QuickJS string creation from invalid UTF-8 | TextDecoder correctness | test replacement behavior; add explicit U+FFFD handling |
| `std.http.Server` body buffering | memory pressure | cap request/response size; document |
| `std.http.Client` concurrency | connection-pool contention | one shared client; each fetch runs in a child task; measure later |
| No TLS server | `https.createServer` missing | documented deferral; users can terminate TLS in a proxy |
| No `*Sync` fs APIs | libraries and CLIs that call `readFileSync`/`mkdirSync` fail | explicit `ERR_METHOD_NOT_IMPLEMENTED` naming the async alternative; document the deviation in the README compatibility table |
| `process.env` mutation semantics | child env mismatch | verify `Environ.Map` mutation in Phase 3; if it cannot mutate, rebuild the map per spawn |
| Unhandled rejections | silent failures in async code | follow-up: track rejected promises without handlers and print a warning |
| Windows behavior | path/fs/chmod differences | POSIX first; Windows best-effort with `@hasDecl` guards |
| npm packages | users expect them | explicit `ERR_MODULE_NOT_FOUND` message and README table |

Open questions:

1. Should `jsz` report a Node-compatible version string (`22.x`) or its own?
   Recommendation: `process.version = "v22.0.0-jsz"` and document it, so
   libraries that parse the major version behave.
2. Should `fs` be gated behind a permission flag (`--allow-fs-read`,
   `--allow-fs-write`)? Node has a permission model. Recommendation: no flag in
   v1; add later if the runtime is embedded.
3. Should `http.Server` support `keep_alive` by default? Recommendation: yes,
   matching Node, with a max-requests cap per connection.
4. Should `fetch` follow redirects across schemes? Recommendation: follow only
   `http`/`https` and cap at 5.
5. Should embedded JS builtins be minified? Recommendation: no; they are small
   and debuggability matters.

---

## 12. Appendix A - coverage matrix

Legend: `now` = exists today, `plan` = in this plan, `defer` = last 10%.

| API | Status | Phase |
| --- | --- | --- |
| `console.log/error` | now | - |
| `setTimeout`/`setInterval`/`clear*` | now | - |
| `sleep(ms)` | now | - |
| ESM `import`/`export` | plan | 0 |
| `node:` and bare builtin specifiers | plan | 0 |
| `import.meta.url`/`main` | plan | 0 |
| `path.*` (posix + win32) | plan | 3B |
| `fs` callbacks (`readFile`, `writeFile`, `appendFile`, ...) | plan | 2 |
| `fs.promises` (same surface) | plan | 2 |
| `fs.mkdir`, `readdir`, `rm`, `rmdir`, `rename`, `copyFile`, `cp` | plan | 2 |
| `fs.stat`, `lstat`, `fstat`, `access`, `realpath` | plan | 2 |
| `fs.chmod`, `chown`, `symlink`, `readlink` | plan | 2 |
| `fs.open/read/write/close` | plan | 2 |
| `fs.*Sync`, `fs.existsSync` | defer | - |
| `fs.watch`, streams | defer | - |
| `process.argv/env/cwd/chdir/exit` | plan | 3A |
| `process.hrtime`, `uptime`, `memoryUsage` | plan | 3A |
| `process.stdout/stderr` | plan | 3A |
| `process.stdin` | defer | - |
| `child_process.spawnSync/execSync` | plan | 4 |
| `child_process.spawn/exec` | plan | 4 |
| `child_process.fork` | defer | - |
| `URL`, `URLSearchParams` | plan | 3B |
| `url.pathToFileURL`, `fileURLToPath` | plan | 3B |
| `http.createServer` | plan | 5 |
| `http.request`, `https.*` | defer | - |
| `fetch`, `Headers`, `Response` | plan | 5 |
| `crypto.createHash`, `createHmac` | plan | 3A |
| `crypto.randomBytes/UUID/randomInt/getRandomValues` | plan | 3A |
| `crypto.timingSafeEqual`, `webcrypto.subtle` | defer | - |
| `util.format/inspect/types/promisify` | plan | 3B |
| `events.EventEmitter` | plan | 3B |
| `os.platform/arch/homedir/tmpdir/cpus` | plan | 3A |
| `os.networkInterfaces` | defer | - |
| `Buffer` | plan | 1 |
| `TextEncoder`/`TextDecoder`/`atob`/`btoa` | plan | 1 |
| `net`, `tls`, `dns`, `zlib`, `worker_threads`, `readline`, `assert` | defer | - |

---

## 13. Appendix B - module load sequence

```text
jsz script.mjs
  │
  ├─ CLI parses argv, resolves script to an absolute path
  ├─ Runtime.init
  │    ├─ zio.Runtime.init(executors = 1)
  │    ├─ quickjs.Runtime/Context
  │    ├─ EventLoop (timer list, completion channel)
  │    └─ setModuleLoaderFunc(normalize, load)
  │
  ├─ read entry source
  ├─ ctx.eval(source, filename, .{ .type = .module | .global })
  │    ├─ QuickJS parses imports
  │    ├─ normalize(base, spec) -> canonical name
  │    ├─ load(name)
  │    │    ├─ builtin -> embedded JS or C module
  │    │    └─ file -> read, compile-only, import.meta
  │    └─ QuickJS instantiates and links
  │
  ├─ if entry has TLA: settle its promise while running the loop
  ├─ EventLoop.run
  │    ├─ select(timer, completion)
  │    ├─ dispatch job -> resolve/reject JS promise
  │    └─ fire due timers -> drain jobs
  │
  └─ flush, deinit, exit code
```

---

## 14. Appendix C - research constraints

- `zigdoc std.*` works under Zig 0.17.0; all `std` signatures above were
  checked with it unless marked as a gap.
- `zigdoc zio.*` and `zigdoc quickjs.*` fail with `error: UnsupportedZigVersion`
  because the tool does not yet parse this project's dependency graph under
  0.17. zio and QuickJS facts were read from the vendored sources:
  - `~/.cache/zig/p/zio-0.19.0-.../src/`
  - `~/.cache/zig/p/quickjs_ng-0.0.0-.../src/`
  - upstream QuickJS-ng `quickjs.c` for the module loader pattern.
- Re-run `zigdoc` on every zio/QuickJS symbol before implementing a phase; if
  the tool still fails, compile a throwaway probe instead of trusting memory.
- QuickJS-ng lacks `URL`, `URLSearchParams`, `TextEncoder`, `TextDecoder`,
  `structuredClone`, `AbortController`, `fetch`, `atob`, and `btoa`. It does
  provide `queueMicrotask`. This is why those globals are part of the plan
  rather than assumed.
