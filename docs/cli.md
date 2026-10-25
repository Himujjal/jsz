# CLI

## Usage

```text
Usage: jsz [options] [script]

Run a JavaScript file, evaluate an expression, or start the REPL.

Options:
  -e, --eval <code>   Evaluate code
  -h, --help          Show this help
  -v, --version       Show version

Commands:
  repl                Start the REPL
```

Running `jsz` with no arguments starts the REPL. The CLI accepts at most one script path. If both `--eval` and a script are present, eval mode is used.

## Arguments

| Argument | Description |
| --- | --- |
| `[script]` | Run a JavaScript file. |
| `-e`, `--eval <code>` | Evaluate the code string instead of running a file. |
| `-h`, `--help` | Print the usage text to stdout and exit. |
| `-v`, `--version` | Print `jsz <version>` to stdout and exit. |
| `repl` | Start the interactive REPL. |

`--help` and `--version` are handled before the runtime is created. Both write to stdout and flush immediately. An `--eval` without a following value fails with `error.MissingEvalSource`. A second script path fails with `error.UnexpectedArgument`.

## Output

The CLI creates one stdout writer at startup and shares it with the runtime. This matters because each `std.Io.File.stdout()` writer starts at offset 0; creating a new writer for each message would overwrite earlier output. One writer preserves ordering.

The runtime accumulates `console.log` and `console.error` output in a buffer. `Runtime.flush()` writes that buffer through the shared writer and clears it. Both console methods use the same runtime output path.

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
