# jsz

A small JavaScript runtime written in Zig 0.17 that embeds QuickJS and uses zio for timers and async I/O.

## Status

jsz is a learning and systems project, not a Node.js replacement. v0.1 is intentionally small. Its complete supported surface is:

- `console.log` and `console.error`
- `setTimeout` / `clearTimeout`
- `setInterval` / `clearInterval`
- `sleep(ms)`
- Native QuickJS Promises, including `then`, `catch`, `finally`, `Promise.all`, and `async` / `await`
- A CLI that runs script files, evaluates code with `-e` / `--eval`, prints help and version information, and starts a REPL with the `repl` command or no arguments

v0.1 does not support ES modules or `import`, filesystem access, network access, child processes, npm packages, Node.js API compatibility, TypeScript, or top-level `await` outside async functions. See the [roadmap](docs/roadmap.md) for the full scope, limitations, and possible next steps.

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

| API | Behavior |
| --- | --- |
| `console.log(...values)` | Converts each value with JavaScript `toString`, joins arguments with spaces, and appends a newline. |
| `console.error(...values)` | Uses the same formatting and output path as `console.log`. |
| `setTimeout(callback, delayMs, ...args)` | Schedules a one-shot callback and returns a numeric timer id. |
| `clearTimeout(id)` | Cancels a pending timeout. |
| `setInterval(callback, delayMs, ...args)` | Schedules a repeating callback and returns a numeric timer id. |
| `clearInterval(id)` | Cancels a pending interval. |
| `sleep(ms)` | Returns a native QuickJS Promise that resolves after the delay. |
| Promises | Native QuickJS `then`, `catch`, `finally`, `Promise.all`, `async`, and `await`. |

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
│   ├── runtime.zig           owns the zio runtime, QuickJS runtime/context, and event loop
│   ├── event_loop.zig        timer scheduling, job draining, and run guards
│   ├── cli/
│   │   └── cli.zig           argument parsing, script/eval/REPL dispatch, shared stdout writer
│   └── js/
│       ├── host.zig          host state stored in the QuickJS context opaque pointer
│       ├── builtins.zig      installs globals on the QuickJS context
│       ├── timers.zig        setTimeout, setInterval, clearTimeout, clearInterval
│       ├── promises.zig      sleep(ms) host promise
│       └── console.zig       console.log and console.error
├── tests/
│   ├── zig/                  Zig integration tests and fixture harness
│   └── fixtures/             JavaScript fixtures used by the test harness
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
