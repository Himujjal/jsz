# Roadmap

This page records the v0.1 scope, the limits that come with it, and possible directions. The next steps are ideas, not commitments, and the order is approximate.

## v0.1 shipped

- [x] `console.log` and `console.error` with JavaScript `toString` formatting and space-separated arguments
- [x] `setTimeout(callback, delayMs, ...args)` and `clearTimeout(id)`
- [x] `setInterval(callback, delayMs, ...args)` and `clearInterval(id)`
- [x] `sleep(ms)` as a host function returning a native QuickJS Promise
- [x] Native QuickJS Promises: `then`, `catch`, `finally`, `Promise.all`, `async`, and `await`
- [x] CLI script execution, `-e` / `--eval`, `-h` / `--help`, and `-v` / `--version`
- [x] Interactive REPL started by `repl` or by running with no arguments, with `.exit` and EOF handling
- [x] Event loop with timer ordering, interval re-arming, cancellation, `max_iterations`, and `max_runtime_ms`
- [x] Zig integration tests and JavaScript fixtures
- [x] mise tasks, hk pre-commit checks, and a Forgejo Actions CI and release workflow

## Non-goals for v0.1

These are intentional exclusions, not missing pieces:

- ES modules and `import`
- Filesystem access
- Network access
- Child processes
- npm packages
- Node.js API compatibility
- TypeScript
- Top-level `await` outside async functions

## Known limitations

- No module system. Scripts are evaluated as a single source unit, so `import` and `export` are unavailable.
- No unhandled rejection reporting. A rejected promise without a handler is not reported by the runtime.
- Timer delays are clamped to 2,147,483,647 ms.
- JavaScript is single-threaded. All QuickJS calls run on the main zio task, and there are no worker threads.
- No source maps. Stack traces refer to the evaluated source without a mapping layer.

## Possible next steps

These are ideas, not commitments.

1. **ES modules.** Add module loading, path resolution, and `import` / `export` support. This would require a loader and a decision about how modules interact with the single-source evaluation model.
2. **Filesystem API.** Expose file reads and writes, likely as asynchronous operations driven by zio. This would also require deciding which paths scripts may access.
3. **Unhandled rejection reporting.** Track rejected promises that never receive a handler and report them with a stack trace. This would also require deciding whether an unhandled rejection should stop the process or only print a warning.
4. **Richer console formatting.** Improve value inspection for objects and arrays, and consider format specifiers or separate stderr routing for `console.error`.
5. **HTTP and networking.** Add TCP and HTTP client or server APIs backed by zio. This would be a substantial expansion of the runtime surface.
6. **Worker threads.** Run JavaScript on multiple threads with message passing. This conflicts with the current single-threaded design and would require one QuickJS context per worker plus a careful ownership model.
