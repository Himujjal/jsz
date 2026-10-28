# jsz

A small JavaScript runtime written in Zig 0.17 that embeds QuickJS and uses zio for timers and async I/O.

## Status

jsz implements Node.js 22 compatibility phases 0-5 from the
[plan](docs/plan/plan.md): an ESM module loader, async filesystem, `process`,
`os`, `crypto`, `child_process`, `path`, `url`, `util`, `events`, `Buffer`,
TCP (`node:net`), `http.createServer`/`http.request`/`http.get`,
`https.createServer`/`https.request`/`https.get`, and a global
`fetch`/`Headers`/`Response`/`Request` over vendored dusty 0.5.0. All I/O runs
on zio tasks while QuickJS stays on the single JS task.

HTTP responses stream on both sides: the server sends `res.write` chunks as they
arrive with a 64 KiB high-water mark driving `drain` backpressure, and client
response bodies arrive through `IncomingMessage` `data`/`end`/`close`. `https`
accepts `ca`, `cert`/`key`, `pfx`/`passphrase`, and `rejectUnauthorized` on the
client and supports PEM, PFX, and mTLS on the server.

Still deferred (the last 10%): full Node streams and web streams, streaming
`fetch` bodies and HTTP request bodies, trailers, interim 1xx responses, the
`tls` module, `dns`, `zlib`, `worker_threads`, `readline`, `assert`, `fs.watch`,
`fs` `*Sync` entry points, UDP, and `child_process.fork`. See the
[roadmap](docs/roadmap.md) for the current list.

## Requirements

- [mise](https://mise.jdx.dev/), which installs Zig 0.17.0 and hk 2.8.1 from `mise.toml`
- No system Node.js installation is needed

## Quickstart

```sh
mise install
mise run build
mise run run examples/timers.js
mise run repl
mise run test
```

`mise run build` produces `zig-out/bin/jsz`. You can also run it directly:

```sh
./zig-out/bin/jsz examples/promises.js
```

## Supported API

| Area | Surface |
| --- | --- |
| Modules | ESM `import`/`export`, `node:` and bare builtin specifiers, `import.meta`, dynamic `import()` |
| Filesystem | `fs`/`fs/promises` async callbacks and promises; no `*Sync` or `fs.watch` |
| Process | `process.argv`, `env`, `cwd`, `chdir`, `exit`, `hrtime`, `stdout`/`stderr`, signals, `uncaughtException` |
| Runtime | `console`, timers, `queueMicrotask`, native Promises, `Buffer`, `TextEncoder`/`TextDecoder`, `atob`/`btoa`, `URL`, `URLSearchParams` |
| System | `os`, `crypto` (hash, HMAC, random), `path` (posix + win32), `util`, `events`, `child_process` |
| Network | `net.createServer`/`net.connect` (TCP), `http.createServer`/`http.request`/`http.get`, `https.createServer`/`https.request`/`https.get`, global `fetch`, `Headers`, `Response`, `Request` |

The HTTP server and client use a vendored [dusty](https://github.com/lalinsky/dusty)
0.5.0 (`vendor/dusty`) over zio's `std.Io` implementation. The vendored copy
carries a small patch so the response status line can carry a numeric code and a
caller-supplied reason phrase, and so the client parser accepts status codes its
`Status` enum does not name. JavaScript is single-threaded; file, child, network,
and fetch work runs in zio tasks and completes through the event loop.

Timer delays are clamped to 2,147,483,647 ms. A timer callback must be a function.

## Example

```js
setTimeout(() => {
    console.log("timer");
}, 10);

async function main() {
    console.log("start");
    await sleep(20);
    console.log("after sleep");
}

main();
```

## Project layout

```text
.
├── build.zig                 build graph for the module, executable, and tests
├── build.zig.zon             pinned QuickJS and zio dependencies; minimum Zig version
├── mise.toml                 Zig and hk tool pins plus developer tasks
├── hk.pkl                    pre-commit checks for format, build, and tests
├── src/
│   ├── main.zig              process entry point; receives std.process.Init
│   ├── root.zig              public module exports and version string
│   ├── runtime.zig           zio runtime, QuickJS runtime/context, host wiring
│   ├── event_loop.zig        timers, completion queue, job draining, run guards
│   ├── module.zig            ESM resolver, builtin registry, module loader
│   ├── jobs.zig              I/O task -> JS task completion queue
│   ├── fs.zig                async filesystem coordinator
│   ├── child_process.zig     child-process coordinator
│   ├── net.zig               TCP server/socket coordinator
│   ├── http.zig              dusty-backed HTTP server coordinator
│   ├── fetch.zig             dusty-backed HTTP/HTTPS client coordinator
│   ├── pkcs12.zig            pure-Zig PKCS#12/PFX parser for `https` `pfx`
│   ├── builtins/             embedded ESM modules (path, fs, http, https, net, ...)
│   ├── js/                   native QuickJS modules, host, value helpers
│   └── cli/cli.zig           argument parsing, script/eval/REPL dispatch
├── tests/
│   ├── zig/                  Zig integration tests and fixture harness
│   └── fixtures/             JavaScript fixtures, including net/http/https/fetch
├── vendor/dusty/             dusty 0.5.0 with the numeric status-line patch
├── examples/                 runnable demo scripts
├── docs/                     architecture, CLI, testing, and roadmap notes
└── .forgejo/workflows/       Forgejo Actions CI and release workflow
```

## Development tasks

| Task | Description |
| --- | --- |
| `mise run fmt` | Format Zig sources with `zig fmt`. |
| `mise run fmt-check` | Check formatting without changing files. |
| `mise run build` | Build the debug CLI. |
| `mise run build-release` | Build with `-Doptimize=ReleaseSafe`. |
| `mise run test` | Run Zig integration tests and JavaScript fixtures. |
| `mise run run` | Run a script; arguments after the task name are forwarded. |
| `mise run repl` | Start the interactive REPL. |
| `mise run test-watch` | Re-run tests on change with `zig build test --watch`. |
| `mise run run-watch` | Restart the CLI on change with `mise watch`. |
| `mise run check` | Run format check, build, and tests. |
| `mise run ci` | Run format check, a ReleaseSafe build, and tests. |
| `mise run doc` | List the documentation entry points. |
| `mise run install-hooks` | Install hk git hooks. |

`mise run run` forwards script arguments, for example:

```sh
mise run run examples/timers.js
```

## Documentation

- [Architecture](docs/architecture.md): components, lifecycle, event loop, promises, ownership.
- [CLI](docs/cli.md): flags, REPL behavior, exit codes, examples.
- [Testing](docs/testing.md): test layers, fixtures, guards, and commands.
- [Roadmap](docs/roadmap.md): shipped scope, non-goals, limitations, and possible next steps.

## Commits

Use Conventional Commits, for example `feat(runtime): add sleep()`. Keep one logical change per commit.
