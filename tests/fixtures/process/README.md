# process fixtures

Ported from `tests/fixtures/node/process/` (Node.js `test/parallel`, snapshot
`62b4717`). These are runnable under jsz: ESM only, deterministic
`console.log` output, no `test/common`, no `assert`.

They are driven by `tests/zig/process_test.zig` through
`helpers.runFixtureProcess`, which supplies `process.argv` and the environment.

## Covered

| Fixture | Upstream test(s) |
| --- | --- |
| `argv.js` | `test-process-argv-0.js` |
| `cwd.js` | `test-process-chdir.js` |
| `cwd-error.js` | `test-process-chdir-errormessage.js` |
| `env.js` | `test-process-env.js`, `test-process-env-delete.js` |
| `hrtime.js` | `test-process-hrtime.js`, `test-process-hrtime-bigint.js` |
| `uptime.js` | `test-process-uptime.js` |
| `identity.js` | `test-process-default.js`, `test-process-ppid.js`, `test-process-versions.js` |
| `exit-code.js` | `test-process-exit-code.js`, `test-process-exit.js` |

## Not ported (deferred)

| Upstream test | Reason |
| --- | --- |
| `test-process-cpuUsage.js` | `process.cpuUsage` not implemented |
| `test-process-emit.js` | needs `events.EventEmitter`; `process.on`/`emit` deferred |
| `test-process-emitwarning.js` | `process.emitWarning` deferred |
| `test-process-env-sideeffects.js` | needs `inspector`, out of scope |
| `test-process-exec-argv.js` | needs `child_process` (Phase 4) |
| `test-process-execpath.js` | `process.execPath` deferred; needs `child_process` |
| `test-process-exit-code-validation.js` | exit validation is range-only for now |
| `test-process-exit-handler.js` | needs `process.on('exit')` and `events` |
| `test-process-next-tick.js` | `process.nextTick` deferred to the async/events pass |
| `test-process-title.js`, `test-process-title-cli.js` | `process.title` deferred |
| `test-process-umask.js`, `test-process-umask-mask.js` | `process.umask` deferred |

## Invariants these fixtures rely on

- `process.argv[1]` is the absolute resolved script path for file execution.
- `process.env` reads and mutates the live environment map, so inherited values
  are visible and `delete` removes the key.
- `process.exit(code)` stops the loop (pending timers do not fire) and the CLI
  exits with `code` after flushing stdout.
