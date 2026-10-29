# Testing

For a first pass, run `mise install` and `mise run test` from the repository
root. This builds the test dependencies and runs the integration suite;
`mise run check` also checks formatting and builds both executables. See
[architecture](architecture.md) for runtime ownership and
[CLI](cli.md) for manual invocation.

## Test layers

jsz has two test layers:

1. Zig integration tests in `tests/zig`. They import the `jsz` module, create a
   runtime, evaluate JavaScript, and inspect values, captured stdout, and exit
   codes.
2. JavaScript fixtures in `tests/fixtures`. The Zig harness runs each fixture
   through a real runtime (or the installed CLI), and compares
   `globalThis.__result`, captured stdout, or the exit code.

Both layers use `std.testing.allocator`, so memory leaks fail the suite. Network
fixtures bind ephemeral ports, clean up their servers, and use a watchdog timer
that prints `timeout` and exits non-zero when an operation hangs.

## File map

| Path | Purpose |
| --- | --- |
| `tests/zig/main.zig` | Test root; imports every test file below. |
| `tests/zig/helpers.zig` | Runtime setup, stdout capture, fixture execution, argv/env, and process results. |
| `tests/zig/runtime_test.zig` | Evaluation, syntax errors, promise jobs, invalid timer callbacks, and the version export. |
| `tests/zig/timers_test.zig` | Microtask/timer ordering, callback arguments, `clearTimeout`, `clearInterval`, and the iteration guard. |
| `tests/zig/promises_test.zig` | `Promise.all`, `sleep`, chained sleeps, and promise-timer cancellation. |
| `tests/zig/module_test.zig` | Builtin resolution, embedded modules, relative imports, cycles, and `import.meta`. |
| `tests/zig/fs_test.zig` | Async filesystem paths, descriptors, errors, and sync guards. |
| `tests/zig/process_test.zig` | `process.argv`, env, cwd, exit hooks, signals, and error shapes. |
| `tests/zig/os_test.zig`, `crypto_test.zig`, `url_test.zig`, `util_test.zig`, `events_test.zig` | Phase 3A/3B surfaces. |
| `tests/zig/child_process_test.zig` | Sync/async children, output, stdin, signals, and timeouts. |
| `tests/zig/net_test.zig` | TCP echo, connection refusal, and shutdown with live handles. |
| `tests/zig/http_test.zig` | `http.createServer` request/response, streamed chunks with a raw chunked framing check, custom status line, declared length and `drain`, `http.request`/`http.get`, `https.createServer`, `https.request` handshake/streaming/insecure, mTLS and PFX certificates, close draining, and shutdown with a live listener. |
| `tests/zig/pkcs12_test.zig` | PKCS#12/PFX parsing: encrypted PFX to PEM, legacy LibreSSL PBE algorithms, malformed input, and wrong passphrases (modern and legacy). |
| `tests/zig/fetch_test.zig` | Global `fetch` against a local `http` server, redirect modes, final URLs, in-flight abort, and the `599 Custom Reason` status line. |
| `tests/zig/differential_test.zig` | Optional parity check: runs the differential corpus through jsz and a real `node`, then compares stdout byte-for-byte. |
| `tests/zig/electron_test.zig` | `electron` role gating, main-process exports, CLI validation, and an opt-in native-window IPC round trip. |
| `tests/zig/sea_test.zig` | `jszc` payload embedding, `argv`/`import.meta`, embedded assets and `node:sea`, desktop payload activation, JSON config, and the input-overwrite guard. |
| `tests/fixtures/sea/` | Entry script used to prove a compiled executable no longer reads its source. |
| `tests/fixtures/modules/` | ESM imports, cycles, dynamic import, and resolution errors. |
| `tests/fixtures/net/` | TCP echo, `ECONNREFUSED`, and live-handle shutdown. |
| `tests/fixtures/http/` | HTTP server/fetch round trip, `http.request`/`http.get`, server response streaming over raw `net` framing, close draining, and live-listener shutdown. |
| `tests/fixtures/https/` | `https.createServer` bind/close with PEM, client handshake with CA verification, streaming and `rejectUnauthorized: false`, mTLS, and PFX on both sides. |
| `tests/fixtures/fetch/` | `fetch`, `Headers`, JSON, POST echo, 404, redirects, redirect modes, final URLs, and abort. |
| `tests/fixtures/node/` | Curated fixtures ported from the Node.js test suite. |
| `tests/fixtures/differential/` | The deterministic corpus compared against a real `node` binary. |
| `tests/fixtures/electron/` | Main/preload/page trio for the desktop bridge, plus disabled- and main-role fixtures. |

## Guards and helpers

`helpers.initRuntime(writer)` creates a runtime with:

- `max_runtime_ms = 5_000`
- `max_iterations = 10_000`

The writer is optional. Tests that inspect output pass a `std.Io.Writer.Allocating`; tests that only inspect values pass `null`.

`helpers.readResult(allocator, runtime)` evaluates `globalThis.__result`, converts the value to a C string, and duplicates it for the caller.

`helpers.runFixture(allocator, name)` creates a runtime with an allocating
writer, joins `fixtures_dir` and the fixture name, evaluates the file, runs the
loop, and returns `globalThis.__result`. `helpers.runFixtureStdout` returns the
captured stdout instead, and `helpers.runFixtureProcess` accepts explicit argv
and environment plus an exit code. `fixtures_dir` is supplied by the build
option and points at `tests/fixtures`.

## Fixture contract

A fixture must:

- Set `globalThis.__result` or print deterministic stdout for the harness.
- Finish on its own. Clear intervals, close servers and sockets, and do not
  schedule work that keeps the loop alive indefinitely.
- Stay within the runtime guards of 5 seconds and 10,000 loop iterations.
- Clean up temporary files and avoid fixed ports.

The harness does not inject an assertion library. The `errors.js` fixture is the
exception to the normal contract: it intentionally throws inside a timer, and
its test expects `error.JavaScriptError` plus `boom` in the captured output.

Network fixtures use a `setTimeout` watchdog that prints `timeout` and calls
`process.exit(1)` so a hang fails fast instead of waiting for the runtime guard.

## Desktop tests

`tests/zig/electron_test.zig` covers the headless parts of `--desktop` by
default: `electron` is rejected outside desktop mode, the main role exposes only
the main-process surface, and the CLI rejects `--desktop` without a script or
with `--eval`.

The native-window round trip is opt-in because it opens a visible WKWebView and
requires a logged-in macOS session:

```sh
JSZ_DESKTOP_TESTS=1 mise run test
```

The fixture (`tests/fixtures/electron/main.mjs`) creates a window, loads
`index.html` through a preload, performs an `ipcRenderer.invoke`/`ipcMain.handle`
round trip, prints `desktop=ok:hello:true`, and quits. A 20-second watchdog
exits non-zero if the bridge stalls.

## Single executable tests

`tests/zig/sea_test.zig` invokes the installed `jszc` to compile
`tests/fixtures/sea/main.mjs` into a temporary executable. It deletes the
source, runs the executable with arguments, and checks `process.argv`,
`import.meta.url`, `import.meta.main`, and stdout. Further cases cover
`--config`, embedded assets and `node:sea`, desktop-mode activation, and the
guard that refuses an output path equal to the input script.

The full desktop round trip is opt-in because it opens a window. It compiles the
Electron fixture with its preload and HTML as assets and expects
`desktop=ok:hello:true`:

```sh
JSZ_DESKTOP_TESTS=1 mise run test
```

The tests use `std.testing.tmpDir` and the installed binaries from
`test_options.jszc_exe`; no extra environment variable is required for the
headless cases.

## Differential tests

`tests/zig/differential_test.zig` compares jsz against a real `node` binary. It
runs `tests/fixtures/differential/corpus.mjs` twice: once in-process through
`helpers.runFixtureStdout`, once as a `node` child process. The two stdout
streams must match byte-for-byte. A mismatch fails the test and prints both line
counts plus a unified diff with context.

The corpus is deliberately narrow. It covers `node:path` (posix and win32:
`join`, absolute `resolve`, `normalize`, `dirname`, `basename`, `extname`,
`relative`, `parse`/`format`, `isAbsolute`), `node:buffer` (`Buffer.from` and
`toString` for utf8, hex, base64, base64url, latin1, and utf16le, plus
`Buffer.concat` and `byteLength`), `node:url` (`URL` properties, relative
resolution, mutations, and `URLSearchParams` round-trips), and `node:util`
(`format` with `%s`, `%d`, `%i`, `%f`, `%j`, `%o`, `%O`, `%c`, `%%`, and extra
arguments). Each case prints one `<label>=<value>` line.

Cases must stay deterministic: no time, environment, cwd, network, or
filesystem inputs, and no `resolve` calls that would read the working
directory. The corpus is a regression guard for behavior jsz and node already
agree on, not a record of known divergences.

The test self-skips when `node` is not on `PATH` (it probes with `node
--version` and maps spawn failure to `error.SkipZigTest`), so offline CI stays
green. To require it locally, run the suite with `node` on `PATH`:

```sh
PATH="$(dirname "$(command -v node)"):$PATH" mise run test
```

Check the run report; `differential_test` appears as `SKIP` when the probe
fails and as a normal test otherwise.

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

The suite covers the runtime core, the module loader, async filesystem,
process/os/crypto, path/url/util/events, child processes, TCP, HTTP/HTTPS, PFX
parsing, and fetch. The exact test count changes as coverage grows;
`zig build test` is the source of truth.

| Test file | Coverage |
| --- | --- |
| `runtime_test.zig` | `1 + 1` evaluates to 2; syntax errors report `SyntaxError`; pending promise jobs run; invalid timer callbacks; `jsz.version`. |
| `timers_test.zig` | Microtasks before timers; callback arguments; `clearTimeout`; cleared intervals; iteration guard. |
| `promises_test.zig` | `Promise.all`; `sleep`; chained sleeps; timer cancellation. |
| `module_test.zig` | Builtin aliases, relative imports, cycles, `import.meta`, and resolution errors. |
| `fs_test.zig` | Read/write/append/copy/rm/mkdir/readdir/stat/realpath and descriptor APIs; sync guards. |
| `process_test.zig`, `os_test.zig`, `crypto_test.zig`, `url_test.zig`, `util_test.zig`, `events_test.zig` | Phase 3A/3B behavior. |
| `child_process_test.zig` | `spawnSync`/`execSync`, async streams, stdin, signals, env/cwd, and timeouts. |
| `net_test.zig` | TCP echo (`connected`, `echo:ping`, `server-closed`), `ECONNREFUSED`, and `process.exit` with live handles. |
| `http_test.zig` | `http.createServer` with fetch round trips, keep-alive, `server.close()` draining, streamed response chunks and raw framing, custom status line, `drain`, `http.request`/`http.get`, `https.createServer` bind/close, `https.request` handshake and streaming, mTLS/PFX, and shutdown with a live listener. |
| `pkcs12_test.zig` | PFX parse to PEM with PBES2/AES and legacy PBE, malformed input, wrong passphrase. |
| `fetch_test.zig` | Text, JSON, POST echo, response headers, 404, redirect following, redirect modes, final URLs, in-flight abort, and an arbitrary `599 Custom Reason`. |
| `differential_test.zig` | Optional `node` parity for the deterministic path/buffer/url/util corpus; skips without `node`. |
| `sea_test.zig` | `jszc` output runs without its source, argv/import.meta shape, assets and `node:sea`, desktop payloads, JSON config, and overwrite guard. |

## Adding a test

1. Add a `test "name" { ... }` block to the appropriate file in `tests/zig`.
2. Import `std`, `jsz`, and `helpers.zig` as needed.
3. Create a runtime with `helpers.initRuntime` and always `defer runtime.deinit()`.
4. Deinitialize every `quickjs.Value` returned by `eval` or `evalFile`.
5. Call `runtime.run()` to drain jobs and timers, then read the result with `helpers.readResult`.
6. If you add a new Zig test file, import it from `tests/zig/main.zig`.
7. Run `mise run fmt` and `mise run test`.

To add a fixture:

1. Create `tests/fixtures/<name>.js` or `.mjs`.
2. Set `globalThis.__result` or print deterministic stdout.
3. Clear intervals, close servers/sockets, and clean up temporary files.
4. Add a test in the matching `tests/zig/*_test.zig` that calls
   `helpers.runFixture`, `helpers.runFixtureStdout`, or
   `helpers.runFixtureProcess` and compares the result.

## CI and hooks

`hk.pkl` defines pre-commit checks:

- `zig fmt --check` on `**/*.zig`, excluding `.zig-cache/**` and `zig-out/**`
- `zig build`
- `zig build test`, which depends on `zig build`

The Forgejo Actions workflow in `.forgejo/workflows/ci.yml` runs on push and pull request. It uses a Debian bookworm container, installs Git, curl, and xz, downloads Zig 0.17.0, runs `zig fmt --check`, `zig build test`, and `zig build -Doptimize=ReleaseSafe`, and uploads `zig-out/bin` as an artifact. On `v*` tags it publishes a Forgejo release.

`mise run ci` mirrors the main checks locally: format check, ReleaseSafe build, and tests.
