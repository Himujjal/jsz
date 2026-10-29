# jsz

**A small JavaScript runtime in Zig, with QuickJS under the hood.** Run a script, try a REPL, or package a script and its runtime into a single executable. jsz explores a useful *Node-shaped subset* without claiming to be Node.js: ESM, familiar builtins, asynchronous I/O, and an optional desktop mode backed by the platform WebView.

JavaScript stays on one QuickJS task; [zio](https://github.com/lalinsky/zio) handles timers and I/O tasks. This is an experimental runtime, not a drop-in replacement for Node or Electron.

## Try it

Install [mise](https://mise.jdx.dev/) and build from this repository (the pinned toolchain is Zig 0.17.0):

```sh
mise install
mise run build
./zig-out/bin/jsz -e 'console.log(1 + 1)'
./zig-out/bin/jsz examples/promises.js
```

The eval prints `2`; the promise example prints `start`, `values: a,b`, and `done`. Run `./zig-out/bin/jsz` for the REPL, or `./zig-out/bin/jsz --help` for CLI options. Building and running jsz does not require a system Node.js installation.

A script can use jsz's async builtins and timers:

```js
import { readFile } from 'node:fs/promises';

const text = await readFile('README.md', 'utf8');
console.log(`README: ${text.length} characters`);
await sleep(10);
console.log('done');
```

Save this as `readme.mjs` in the repository root and run `./zig-out/bin/jsz readme.mjs`.

## What is here

| Area | Current scope |
| --- | --- |
| Modules and globals | ESM imports (including dynamic imports), `node:` and bare builtin specifiers; console, timers, promises, `sleep`, `Buffer`, URLs, and text encoding. |
| Files and processes | Async `fs`/`fs/promises`, `path`, `process`, `os`, `crypto` (hash/HMAC/random), `util`, `events`, and a subset of `child_process`. |
| Networking | TCP via `node:net`, HTTP/HTTPS servers and clients, and global `fetch` with `Headers`, `Request`, and `Response`. |
| Packaging | `jszc` embeds a script and the runtime in one executable; optional assets are available through `node:sea`. |
| Desktop | `--desktop` enables an Electron-shaped `electron` subset (`app`, `BrowserWindow`, IPC, dialogs, shell, and a preload bridge) over the native WebView, not Chromium. |

For the exact boundaries, consult the [roadmap](docs/roadmap.md) rather than assuming Node API parity. For example, `fs` has no synchronous entry points; full Node/web streams, streaming fetch bodies, UDP, worker threads, and many Node modules are not implemented. HTTP server request bodies and fetch responses are buffered with size limits. Embedded assets are not a virtual filesystem for regular `fs` reads or module imports.

## Make a single executable

After `mise run build`, create `hello.mjs`:

```js
console.log(`hello ${process.argv.slice(2).join(' ')}`);
```

Then compile and run it:

```sh
./zig-out/bin/jszc hello.mjs -o hello
./hello world
```

This prints `hello world`. The resulting executable contains the script and jsz runtime; it does not need a sibling `jsz`, Zig, or Node installation on a machine with the matching OS and architecture. A `sea.json` can add named assets and opt into desktop mode. See [single-executable apps](docs/single-executable.md) for configuration, `node:sea`, and distribution limitations.

## Desktop experiment

The repository includes a window, preload, IPC, and HTML example:

```sh
./zig-out/bin/jsz --desktop examples/electron/main.mjs
```

It opens a native window on a supported platform. The `electron` builtin is only available with `--desktop`; the API is intentionally much narrower than Electron's. The example also has an [asset configuration](examples/electron/sea.json) for `jszc`. See [CLI and desktop mode](docs/cli.md) for the supported API and caveats.

## Develop and explore

```sh
mise run test       # Zig integration tests and JavaScript fixtures
mise run check      # formatting check, build, and tests
mise run fmt        # format Zig sources
```

Contributions should keep the runtime's small scope and its tests in step; see [AGENTS.md](AGENTS.md) for repository conventions. Useful starting points:

- [Architecture](docs/architecture.md) — runtime, event loop, and ownership.
- [CLI](docs/cli.md) — invocation, REPL, errors, and desktop mode.
- [Single executable apps](docs/single-executable.md) — packaging and assets.
- [Testing](docs/testing.md) — fixtures and test commands.
- [Roadmap](docs/roadmap.md) — shipped features, known limitations, and possible next steps.
