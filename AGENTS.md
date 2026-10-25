# AGENTS.md

`jsz` is a small JavaScript runtime written in Zig 0.17. It embeds QuickJS through
`zig-quickjs-ng` and uses `lalinsky/zio` for timers and async I/O. The CLI runs
scripts, evaluates snippets, and provides a REPL.

## Rule 1: check Zig APIs with zigdoc first

Do not write or change Zig code from memory. Check the real API before editing:

```sh
mise exec -- zigdoc std.ArrayList
mise exec -- zigdoc std.mem.Allocator
mise exec -- zigdoc std.Io.Dir
mise exec -- zigdoc quickjs.Value
mise exec -- zigdoc zio.Runtime
```

`zigdoc` resolves modules declared in `build.zig.zon` and `build.zig`, so it is
the fastest way to confirm signatures. Run `mise exec -- zigdoc -h` for usage.
If `zigdoc` is missing, install it with
`mise use -g github:rockorager/zigdoc` and retry.

## Repository map

```text
build.zig                 build graph: module, executable, run step, test step
build.zig.zon             pinned Zig dependencies and minimum Zig version
mise.toml                 toolchain pins and developer tasks
hk.pkl                    pre-commit checks (format, build, test)
src/main.zig              entry point; receives std.process.Init
src/root.zig              public module exports
src/runtime.zig           owns zio runtime, QuickJS runtime/context, event loop
src/event_loop.zig        timer scheduling, job draining, run guards
src/cli/cli.zig           argument parsing, script/eval/REPL, shared stdout writer
src/js/host.zig           host state stored in the QuickJS context opaque pointer
src/js/builtins.zig       installs globals
src/js/timers.zig         setTimeout/setInterval/clear* bindings
src/js/promises.zig       sleep(ms) host promise
src/js/console.zig        console.log/console.error
tests/zig/                Zig integration tests and fixture harness
tests/fixtures/           JavaScript fixtures used by the test harness
examples/                 runnable demo scripts
docs/                     architecture, CLI, testing, roadmap
.forgejo/workflows/       Forgejo Actions CI and release workflow
```

## Zig 0.17 guidance

These notes are distilled from the Zig 0.17 release notes and language
reference, plus this repository's experience. They are not a substitute for
`zigdoc`.

- Entry point: `pub fn main(init: std.process.Init) !void`. Use `init.gpa` for
  the general allocator and `init.io` for I/O. Do not open-code process setup.
- I/O is explicit. Read files with
  `std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(n))`. When a
  sentinel is required, use `readFileAllocOptions(io, path, allocator, limit,
  .of(u8), 0)`.
- Writers and readers are explicit: `std.Io.File.stdout().writer(io, &buffer)`
  and `std.Io.File.stdin().reader(io, &buffer)`. Each writer starts at offset 0,
  so keep one shared stdout writer per process instead of creating a new one per
  message.
- `std.ArrayList` is unmanaged in 0.17. Pass the allocator to `append`,
  `deinit`, `toOwnedSlice`, and friends. `swapRemove` returns the removed value;
  discard it with `_ =` when unused.
- `Allocator.dupeZ` is gone. Use `dupeSentinel(u8, slice, 0)`.
- Build API changes: `Build.args` is gone, use `run_step.addPassthruArgs()`.
  `Build.pathFromRoot` is gone; use `b.path(...)` or relative paths for runtime
  data.
- `zig build test --watch` is the supported watch command. `zig test --watch`
  does not exist. Do not enable `-fincremental` on macOS aarch64; it currently
  panics with `TODO(MachO2): load archive`.
- Prefer explicit error sets and `try`. Use `defer`/`errdefer` for every QuickJS
  value and allocation. `catch unreachable` is acceptable only for invariants,
  never for I/O or user input.
- Tests should use `std.testing.allocator` so leaks fail the suite.

## QuickJS and zio rules

- Every QuickJS call must run on the same zio task. Do not touch a QuickJS
  context from another thread.
- QuickJS requires the eval buffer to satisfy `input[input_len] == 0`.
  `Runtime.eval` copies input into a sentinel buffer; `evalFile` reads with a
  sentinel. Keep this invariant.
- Timer records own their callback and argument values. The event loop frees
  them exactly once. Do not duplicate arguments that are already owned.
- `sleep(ms)` creates a QuickJS promise capability; the event loop resolves or
  rejects it. Drain QuickJS jobs after callbacks so microtasks run before the
  next timer.
- An uncaught exception in a callback stops the loop and surfaces
  `error.JavaScriptError`. Report `name: message` and the JS stack.

## Code style

- Run `mise run fmt` before committing. CI runs `zig fmt --check`.
- Comments are limited to three lines and explain *why*, not *what*. Prefer
  clear names over narration.
- Keep modules small and dependency direction one-way: `cli` -> `runtime` ->
  `event_loop` -> `js/*` -> `host`.
- Do not add filesystem, network, module loading, or Node.js compatibility
  without updating the roadmap and tests.

## Commands

```sh
mise install          # install Zig 0.17.0 and hk
mise run fmt          # format
mise run fmt-check    # verify formatting
mise run build        # debug build
mise run build-release
mise run test         # Zig integration + fixture tests
mise run test-watch   # zig build test --watch
mise run run examples/timers.js
mise run repl
mise run check        # fmt-check + build + test
mise run ci           # fmt-check + ReleaseSafe build + test
mise run install-hooks
```

## Commit convention

Use Conventional Commits, commitlint style:

```text
<type>(<scope>): <subject>

<body>

<footer>
```

- Types: `feat`, `fix`, `docs`, `test`, `build`, `ci`, `chore`, `refactor`,
  `perf`.
- Scopes: `runtime`, `event-loop`, `cli`, `js`, `deps`, `docs`, `ci`.
- Subject: imperative mood, lowercase after the colon, no trailing period,
  at most 72 characters.
- Body: explain the why in bullet points, wrapped at 72 columns.
- Breaking changes: add `!` after the type/scope and a `BREAKING CHANGE:`
  footer.
- Keep one logical change per commit.

Examples:

```text
feat(runtime): add sleep(ms) host promise
fix(event-loop): reject cancelled sleep timers
docs(cli): document REPL exit behavior
```

## References

- Zig 0.17 release notes: https://ziglang.org/download/0.17.0/release-notes.html
- Zig 0.17 language reference: https://ziglang.org/documentation/0.17.0/
- Project docs: `README.md`, `docs/architecture.md`, `docs/cli.md`,
  `docs/testing.md`, `docs/roadmap.md`
