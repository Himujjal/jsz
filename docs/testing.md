# Testing

## Test layers

jsz has two test layers:

1. Zig integration tests in `tests/zig`. They import the `jsz` module, create a runtime, evaluate JavaScript, and inspect results and output.
2. JavaScript fixtures in `tests/fixtures`. The Zig harness runs each fixture with `evalFile`, lets the event loop finish, and compares `globalThis.__result`.

Both layers use `std.testing.allocator`, so memory leaks fail the suite.

## File map

| Path | Purpose |
| --- | --- |
| `tests/zig/main.zig` | Test root; imports `runtime_test.zig`, `timers_test.zig`, `promises_test.zig`, and `fixtures_test.zig`. |
| `tests/zig/helpers.zig` | Runtime setup with guards, allocating writer capture, result reading, and fixture execution. |
| `tests/zig/runtime_test.zig` | Evaluation, syntax errors, promise jobs, invalid timer callbacks, and the version export. |
| `tests/zig/timers_test.zig` | Microtask and timer ordering, callback arguments, `clearTimeout`, `clearInterval`, and the iteration guard. |
| `tests/zig/promises_test.zig` | `Promise.all`, `sleep`, chained sleeps, and promise-timer cancellation. |
| `tests/zig/fixtures_test.zig` | All seven JavaScript fixtures; `errors.js` checks uncaught timer errors. |
| `tests/fixtures/timers.js` | Timeout ordering, callback arguments, and microtask ordering. |
| `tests/fixtures/intervals.js` | Repeating interval that clears itself after three ticks. |
| `tests/fixtures/promises.js` | `Promise.all` over resolved values. |
| `tests/fixtures/async_await.js` | `async` function awaiting `sleep`. |
| `tests/fixtures/sleep_promise.js` | `new Promise((resolve) => setTimeout(resolve, ms))` awaited twice. |
| `tests/fixtures/long_timer.js` | A 2200 ms timeout, above the i32 nanosecond range, must not fire early. |
| `tests/fixtures/errors.js` | Throws inside a timer to exercise uncaught exception handling. |

## Guards and helpers

`helpers.initRuntime(writer)` creates a runtime with:

- `max_runtime_ms = 5_000`
- `max_iterations = 10_000`

The writer is optional. Tests that inspect output pass a `std.Io.Writer.Allocating`; tests that only inspect values pass `null`.

`helpers.readResult(allocator, runtime)` evaluates `globalThis.__result`, converts the value to a C string, and duplicates it for the caller.

`helpers.runFixture(allocator, name)` creates a runtime with an allocating writer, joins `fixtures_dir` and the fixture name, evaluates the file, runs the loop, and returns the result string. `fixtures_dir` is supplied by the `fixtures_dir` build option and points at `tests/fixtures`.

## Fixture contract

A fixture must:

- Set `globalThis.__result` to the value the test compares.
- Finish on its own. Clear intervals and do not schedule work that keeps the loop alive indefinitely.
- Stay within the runtime guards of 5 seconds and 10,000 loop iterations.

The harness does not inject an assertion library. It runs the fixture, reads `globalThis.__result`, and compares the string in Zig. `helpers.readResult` returns `error.MissingResult` if the result value cannot be converted to a C string. `errors.js` is the exception to the normal contract: it intentionally throws inside a timer, and its test expects `error.JavaScriptError` plus `boom` in the captured output.

## Running tests

```sh
mise install
mise run test
```

The task runs `zig build test`. You can also run `zig build test` directly.

Watch mode:

```sh
mise run test-watch
```

This runs `zig build test --watch`, the native Zig watch command. `zig test --watch` is not supported.

There is no test filter flag. Zig 0.17's test runner does not support one.

## Current coverage

The suite has 21 tests. It covers arithmetic, syntax errors, promise jobs, invalid timer callbacks, microtask-before-timer ordering, callback arguments, `clearTimeout`, `clearInterval`, the iteration guard, `Promise.all`, `sleep`, chained sleeps, timer cancellation rejecting a pending promise with `timer canceled`, the seven fixtures, the long-timer regression, and the version export.

| Test file | Coverage |
| --- | --- |
| `runtime_test.zig` | `1 + 1` evaluates to 2; syntax errors report `SyntaxError`; pending promise jobs run; `setTimeout(42, 0)` reports `callback must be a function`; `jsz.version` is non-empty. |
| `timers_test.zig` | Microtasks run before timers (`mb`); extra callback arguments arrive (`ab`); `clearTimeout` prevents firing; a cleared interval stops at three ticks; an endless interval hits `error.Timeout`. |
| `promises_test.zig` | `Promise.all` resolves values (`1+2`); `sleep` returns a host-created promise; chained sleeps resolve in order (`ab`); cancelling a pending promise timer rejects it with `timer canceled`. |
| `fixtures_test.zig` | `timers.js` yields `mbcad`; `intervals.js` yields `ticks=3`; `promises.js` yields `1+2`; `async_await.js` yields `slept`; `sleep_promise.js` yields `ab`; `long_timer.js` reports at least 2190 ms elapsed; `errors.js` surfaces `error.JavaScriptError` and prints `boom`. |

## Adding a test

1. Add a `test "name" { ... }` block to the appropriate file in `tests/zig`.
2. Import `std`, `jsz`, and `helpers.zig` as needed.
3. Create a runtime with `helpers.initRuntime` and always `defer runtime.deinit()`.
4. Deinitialize every `quickjs.Value` returned by `eval` or `evalFile`.
5. Call `runtime.run()` to drain jobs and timers, then read the result with `helpers.readResult`.
6. If you add a new Zig test file, import it from `tests/zig/main.zig`.
7. Run `mise run fmt` and `mise run test`.

To add a fixture:

1. Create `tests/fixtures/<name>.js`.
2. Set `globalThis.__result` to the expected string.
3. Clear any intervals so the loop terminates.
4. Add a test in `tests/zig/fixtures_test.zig` that calls `helpers.runFixture(std.testing.allocator, "<name>.js")` and compares the returned string.

## CI and hooks

`hk.pkl` defines pre-commit checks:

- `zig fmt --check` on `**/*.zig`, excluding `.zig-cache/**` and `zig-out/**`
- `zig build`
- `zig build test`, which depends on `zig build`

The Forgejo Actions workflow in `.forgejo/workflows/ci.yml` runs on push and pull request. It uses a Debian bookworm container, installs Git, curl, and xz, downloads Zig 0.17.0, runs `zig fmt --check`, `zig build test`, and `zig build -Doptimize=ReleaseSafe`, and uploads `zig-out/bin` as an artifact. On `v*` tags it publishes a Forgejo release.

`mise run ci` mirrors the main checks locally: format check, ReleaseSafe build, and tests.
