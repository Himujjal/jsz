# Single executable apps

`jszc` packages a JavaScript entry point into one executable that embeds both
the `jsz` runtime and the script. It is jsz's equivalent of Node's
[single executable applications](https://nodejs.org/api/single-executable-applications.html),
with a separate build tool so `jsz` stays the lean runtime.

The produced file is a copy of `jsz` with a payload appended. Running it needs
no `jsz`, no Node.js, and no Zig toolchain on the target machine. Embedded
assets can include a preload script and HTML, so Electron-shaped desktop apps
also ship as one file.

## Quickstart

From the repository root, build both binaries and create `hello.mjs`:

```sh
mise run build
cat > hello.mjs <<'JS'
console.log(`hello ${process.argv.slice(2).join(" ")}`);
JS
./zig-out/bin/jszc hello.mjs -o hello
./hello world
# hello world
```

The entry source used here is:

```js
console.log(`hello ${process.argv.slice(2).join(" ")}`);
```

`jszc` copies the runtime it was built with. If the script is removed after
compilation, the executable still runs: the source lives in the payload.

## Desktop apps

A compiled desktop app records the mode and embeds its preload and page. Start
from a `sea.json`:

```json
{
  "main": "main.mjs",
  "output": "hello",
  "desktop": true,
  "assets": {
    "preload.mjs": "preload.mjs",
    "index.html": "index.html"
  }
}
```

```sh
# From the directory containing sea.json, main.mjs, preload.mjs, and index.html:
/path/to/jsz/zig-out/bin/jszc --config sea.json
./hello
```

For a runnable desktop example, use `examples/electron/`. From that directory, run `../../zig-out/bin/jszc --config sea.json` (config paths are relative to the current working directory). Its main script derives paths from the executable's location when packaged:

```js
import { app, BrowserWindow } from "electron";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
await app.whenReady();
const win = new BrowserWindow({
  webPreferences: { preload: join(here, "preload.mjs") },
});
await win.loadFile(join(here, "index.html"));
```

Run from `examples/electron/` with `../../zig-out/bin/jszc --config sea.json` (or use an absolute path to `jszc`); `./desktop-example` then opens the window. Outside a packaged app, the same script can run with `jsz --desktop examples/electron/main.mjs` from the repository root.

Asset lookup matches the tail of the path on a component boundary, so
`<exe-dir>/preload.mjs` finds the embedded `preload.mjs`. `./index.html` and a
bare `index.html` work too.

On first use, embedded assets are extracted to a unique `jsz-sea-*` directory
under `TMPDIR` (or `/tmp`). The desktop backend points WebUI's root folder
there, so relative stylesheets, scripts, and images load normally. The directory
is removed when the runtime shuts down.

## CLI

```text
Usage: jszc [options] <script>

Compile a JavaScript entry point into a standalone executable that
embeds the jsz runtime and the script.

Options:
  -o, --output <path>   Output path (default: script name without extension)
  --config <path>       Read "main", "output", "assets", and "desktop" from JSON
  --jsz <path>          Use a specific jsz binary instead of the embedded one
  --name <name>         Logical name recorded in the payload
  --desktop             Enable the Electron-shaped desktop backend
  -h, --help            Show this help
  -v, --version         Show version
```

Paths in the config are resolved from the current working directory, not from
the config file, matching Node. `--desktop` and `"desktop": true` are
equivalent. On POSIX, the output is created with mode `0755`.

## Config keys

| Key | Type | Behavior |
| --- | --- | --- |
| `main` | string | Entry script. Required unless given on the command line. |
| `output` | string | Executable path. Required unless `-o` is given. |
| `assets` | object | `key -> file path`. Each file is embedded under `key`. |
| `desktop` | boolean | Enables the `electron` builtin at startup. jsz extension. |

Unknown keys are ignored. Node's `useSnapshot`, `useCodeCache`, `execArgv`,
`execArgvExtension`, and `disableExperimentalSEAWarning` are accepted but have
no effect.

Asset keys are relative POSIX paths. `..`, absolute paths, backslashes, and
empty components are rejected with `error.InvalidAssetKey`.

## `node:sea`

Compiled binaries expose the asset API:

```js
import * as sea from "node:sea";

sea.isSea();                       // true inside a jszc binary
sea.getAssetKeys();                // ["preload.mjs", "index.html"]
sea.getAsset("hello.txt");         // ArrayBuffer copy
sea.getAsset("hello.txt", "utf-8"); // decoded string
sea.getRawAsset("hello.txt");      // ArrayBuffer copy
```

Outside a compiled binary, `isSea()` is `false` and the asset functions throw
`ERR_NOT_IN_SINGLE_EXECUTABLE_APPLICATION`; a missing key throws
`ERR_SINGLE_EXECUTABLE_APPLICATION_ASSET_NOT_FOUND`.

`getAssetAsBlob` is not implemented yet.

## Runtime behavior

A compiled binary always runs its embedded script and forwards every argument
to it. It does not interpret `jsz` flags such as `--eval` or `--desktop`.

| Surface | Value |
| --- | --- |
| `process.argv` | `[executablePath, invocationString, ...userArguments]` |
| `process.argv[1]` | The invocation string as typed (for example `./hello`), matching Node SEA |
| `import.meta.url` | `file://<absolute executable path>` |
| `import.meta.main` | `true` |
| `process.execPath` | Absolute executable path |

Module versus script detection uses the recorded source name, so a `.mjs` entry
stays a module and a `.cjs` entry stays a script even though the on-disk path is
an executable. `.js` entries are detected from their syntax.

## Node SEA compatibility

The shape matches Node's single executable applications, but the mechanics
differ:

- Node injects the payload into a Mach-O section, ELF note, or PE resource and
  flips a fuse string. jsz appends a trailer and reads it from the end of the
  executable.
- Node 20-24 run CommonJS only; Node 26 adds `"mainFormat": "module"`. jsz
  detects a module or a script from the recorded source name and syntax, like
  the normal CLI.
- Node's assets are only reachable through `node:sea`. jsz also extracts them
  for the desktop backend, because WebUI needs real files for subresources.
- Node rejects `require()`/`import` of local files from the embedded main. jsz
  resolves them from the executable's directory, so they work when the files
  are shipped next to the binary.
- Node requires the blob producer and target binary to be the same Node
  version. jsz embeds both at build time, so they cannot drift.
- Node removes and re-signs the macOS binary. jsz preserves the linker's ad-hoc
  signature and appends the payload, because `codesign` rejects trailing data.

## Payload format

The executable is `jsz bytes || payload || trailer`.

```text
payload:
  magic       "JSZPAY\0\2"     8 bytes
  version     u16 = 2          2 bytes
  flags       u16              2 bytes   (bit 0: desktop mode)
  name_len    u32              4 bytes
  asset_count u32              4 bytes
  source_len  u64              8 bytes
  reserved    u32              4 bytes
  name        UTF-8
  source      UTF-8
  for each asset:
    key_len   u32              4 bytes
    data_len  u64              8 bytes
    key       UTF-8
    data      bytes

trailer (64 bytes, at end of file):
  magic       "JSZSEA\0\1"     8 bytes
  version     u32              4 bytes
  flags       u32              4 bytes
  length      u64              8 bytes
  sha256      payload digest  32 bytes
  reserved                     8 bytes
```

At startup `jsz` reads the last 64 bytes of its own executable. A missing
trailer means normal CLI mode. A matching trailer with a bad length or digest
fails with `error.CorruptPayload` instead of silently starting the REPL.

## Limitations

- Module imports and `fs` reads do not see embedded assets. Only `node:sea` and
  the desktop preload/HTML lookup read them. Cache files, modules loaded with
  `import()`, and native addons must still exist on disk.
- Assets are extracted to a temp directory for desktop subresources. A hard
  kill can leave a `jsz-sea-*` directory behind.
- `getAssetAsBlob` and Node's VFS mode are not implemented.
- The output is not stripped or compressed. `jszc` embeds a full `jsz` binary,
  so it is roughly twice the runtime size.
- Cross-compilation follows Zig's target: build `jszc` for the same OS and
  architecture as the machines that will run its output.
- `jszc` cannot overwrite its input script or its `--jsz` runtime.

## macOS signing

Zig links macOS binaries with an ad-hoc signature, and `jszc` appends the
payload after it. The resulting binary runs locally, including with the
quarantine attribute set by a download. The signature does not cover the
payload, so Gatekeeper may still ask the recipient to approve the app, and
`codesign` cannot re-sign the file while the trailer is at the end.

For distribution to other Macs, expect the recipient to right-click **Open** or
remove quarantine:

```sh
xattr -dr com.apple.quarantine ./hello
```

Proper notarization needs the payload in a Mach-O section instead of a trailing
blob; that is future work.

## Testing

`tests/zig/sea_test.zig` compiles fixtures with the installed `jszc`, deletes
the source, runs the executable, and checks `argv`, `import.meta`, `node:sea`,
the desktop flag, and the output. The native desktop round trip is opt-in
because it opens a window:

```sh
JSZ_DESKTOP_TESTS=1 mise run test
```
