# CLI

## Usage

```text
Usage: jsz [options] [script] [args...]

Run a JavaScript file, evaluate an expression, or start the REPL.

Options:
  -e, --eval <code>   Evaluate code
  --desktop           Run a main-process script with the native desktop backend
  -h, --help          Show this help
  -v, --version       Show version

Commands:
  repl                Start the REPL
```

Running `jsz` with no arguments starts the REPL. Options are interpreted only until the first script path or the source passed to `-e`/`--eval`. All remaining tokens, including `--help`, `--desktop`, and another path, are forwarded to `process.argv`; they are not parsed as jsz options. For a script, `process.argv` starts with the invocation string and the absolute script path; in eval mode, it starts with the invocation string followed by forwarded arguments.

`jsz` is the runtime. To compile a script into a standalone executable that embeds this runtime, use the separate `jszc` binary; see [single-executable.md](single-executable.md).

## Arguments

| Argument | Description |
| --- | --- |
| `[script] [args...]` | Run a JavaScript file and forward subsequent arguments to it. |
| `-e`, `--eval <code>` | Evaluate the code string instead of running a file. |
| `--desktop` | Run a main-process script with the native WebView backend and the `electron` builtin. Requires a script path; rejects `--eval` and the REPL. |
| `-h`, `--help` | Print the usage text to stdout and exit. |
| `-v`, `--version` | Print `jsz <version>` to stdout and exit. |
| `repl` | Start the interactive REPL. |

`--help` and `--version` are handled before the runtime is created **when they occur before a script or eval source**. Both write to stdout and flush immediately. An `--eval` without a following value fails with `error.MissingEvalSource`. `--desktop` must precede the script and cannot be combined with eval mode. The `repl` token is ignored while parsing options, so `jsz repl` starts the REPL, but `jsz file.js repl` forwards `repl` to the script.

For example, after `mise run build`:

```sh
./zig-out/bin/jsz -e 'console.log(JSON.stringify(process.argv.slice(1)))' --help ./other.js
# prints ["--help","./other.js"]
./zig-out/bin/jsz examples/timers.js --version
# runs the script; --version is a script argument
```

If you use `mise run run`, pass runtime arguments after the task name, for example `mise run run examples/timers.js --version`.

## Output

The CLI creates one stdout writer at startup and shares it with the runtime. This matters because each `std.Io.File.stdout()` writer starts at offset 0; creating a new writer for each message would overwrite earlier output. One writer preserves ordering.

The runtime buffers console output before flushing it through the shared stdout writer. Both the native `console.log` and `console.error` writers append to that same buffer; the JavaScript console facade formats their arguments, but its `error`/`warn` methods still use the shared output path. Do not rely on stderr separation for console output.

## REPL

Start the REPL with:

```sh
mise run repl
```

The prompt is `jsz> `. Input is read one line at a time:

- An empty line is ignored.
- `.exit` exits the REPL.
- End of file (EOF) exits the REPL.
- Any other line is evaluated with the filename `<repl>`.
- The result value is converted with JavaScript `toString` and printed on its own line.
- After evaluation, the runtime performs one non-blocking tick to drain promise jobs and fire due timers, then flushes output.
- An evaluation or tick error is reported and the REPL continues with the next line.

Example:

```text
$ mise run repl
jsz> 1 + 1
2
jsz> .exit
```

## Desktop mode

`jsz --desktop main.mjs` runs a main-process ESM script with an
Electron-shaped, deliberately small `electron` builtin:

```js
import { app, BrowserWindow, ipcMain } from 'electron';

await app.whenReady();
ipcMain.handle('echo', (_event, value) => value);
const win = new BrowserWindow({
  width: 800,
  height: 600,
  webPreferences: { preload: '/absolute/path/preload.mjs' },
});
await win.loadFile('/absolute/path/index.html');
```

The preload script runs in a separate QuickJS context and may import only
`electron` (`contextBridge`, `ipcRenderer`). The page gets only the properties
passed to `contextBridge.exposeInMainWorld`. `BrowserWindow` uses the platform
WebView through zig-webui: WKWebView on macOS, WebView2 on Windows, and
WebKitGTK on Linux. It does not bundle Chromium.

Supported main exports are `app`, `BrowserWindow`, `ipcMain`, `dialog`, and
`shell`. `node:electron` is always `ERR_UNKNOWN_BUILTIN_MODULE`. Importing
`electron` outside desktop mode fails with `ERR_DESKTOP_NOT_ENABLED`; there is
no npm `electron` fallback.

Limitations: the preload is a jsz context, not a Chromium isolated world; the
bridge has no per-navigation sender binding yet; `ready-to-show`, DevTools,
window bounds, menus, and trays are not exposed. `dialog.showOpenDialog` uses
the native OS picker through `osascript` on macOS. `shell.openExternal` accepts
only `http:` and `https:` URLs.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success, including `--help`, `--version`, `.exit`, and EOF in the REPL. |
| `1` | Usage or runtime error. |

When an error reaches `main`, the CLI prints `jsz: <ErrorName>` and exits with status 1. JavaScript syntax errors and uncaught exceptions surface as `error.JavaScriptError`. Errors inside the REPL are reported without exiting the REPL.

## Examples

Run the timer example:

```sh
mise run run examples/timers.js
```

This prints `start`, three `tick` lines, then `done`.

Run the promise example:

```sh
mise run run examples/promises.js
```

This prints:

```text
start
values: a,b
done
```

Run the Promise-wrapped timer example:

```sh
mise run run examples/sleep_promise.js
```

This prints `start`, `slept`, then `done`.

Run the built binary directly:

```sh
./zig-out/bin/jsz examples/timers.js
```

Evaluate an expression:

```sh
./zig-out/bin/jsz -e 'console.log(1 + 1)'
```

This prints `2`.

Start the REPL with no arguments:

```sh
./zig-out/bin/jsz
```

Print help or version:

```sh
./zig-out/bin/jsz --help
./zig-out/bin/jsz --version
```
