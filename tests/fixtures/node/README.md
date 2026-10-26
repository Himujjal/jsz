# Node.js test corpus (porting source)

Raw copies of selected tests from the official Node.js test suite. These are
the behavioral ground truth for jsz's Node compatibility work (see
`docs/plan/plan.md` §10.1). They are **not yet runnable under jsz**: they are
CommonJS, use `node:test`/`test/common`, and target Node's full API surface.
Each phase ports/adapts the relevant subset into `tests/fixtures/*.js` ESM
fixtures with deterministic `console.log` output.

## Provenance

- Source: `nodejs/node` @ `62b4717` (partial clone, `test/parallel` +
  `test/sequential`)
- Local path: `/private/var/folders/7b/3zt0gmk10ynfm5byf21zymnm0000gn/T/opencode/node-src`
- Original filenames are preserved (`test-<module>-<topic>.js`).

## Selection rules (from docs/plan/plan.md)

Only APIs inside the 90% target are included. Excluded by design:

- **fs**: `*Sync` (jsz's fs is async-only; `*Sync` throws
  `ERR_METHOD_NOT_IMPLEMENTED`), `fs.watch*`, streams (`createReadStream`/
  `createWriteStream`), `FileHandle` (`promises-file-handle-*`), `opendir*`,
  `glob*`, `statfs`, `readv`/`writev`, buffer-encoding `readdir`/`readlink`
  variants, Windows-only paths (`*-junction*`, `*-drive-win*`).
- **crypto**: only `hash`, `hmac`, `random*`, `randomUUID` (no ciphers, no
  `randomFill*`, no `randomUUIDv7`, no stream hashing).
- **process**: only argv/env/cwd/chdir/exit/hrtime/uptime/nextTick/emitWarning/
  title/umask/versions/pid surface. No binding/dlopen/execve/kill/uid/timeout/
  beforeExit/abort tests.
- **url**: WHATWG (`URL`/`URLSearchParams`) and `pathToFileURL`/
  `fileURLToPath` only. No legacy `url.parse`/`format`/`resolve`, no punycode.
- **child_process**: `spawn`/`spawnSync`/`exec`/`execSync`/`execFile`/
  `execFileSync` only. No `fork`, no AbortController/timeout variants.
- **http**: `http.createServer` core only. No request-timeout/
  keep-alive-timeout/cluster/trailer/upgrade tests.
- **os/util/events/path**: plan surface only (no `util.styleText`, `debounce`,
  `throttle`, `getCallsites`, `path.glob`, `EventEmitter` AbortSignal extras).

## Layout

| Dir | Plan phase | Count |
| --- | --- | --- |
| `fs/` | 2 - Filesystem | 145 |
| `process/` | 3A | 26 |
| `os/` | 3A | 4 |
| `crypto/` | 3A | 6 |
| `path/` | 3B | 15 |
| `url/` | 3B | 7 |
| `util/` | 3B | 14 |
| `events/` | 3B | 6 |
| `child_process/` | 4 | 27 |
| `http/` | 5 | 17 |
| `fetch/` | 5 | 1 |

Some copied tests still reference `test/fixtures/` data files from the Node
repo (not yet sparse-checked-out). When porting a test that needs one, pull it
with:

```sh
cd /private/var/folders/7b/3zt0gmk10ynfm5byf21zymnm0000gn/T/opencode/node-src
git sparse-checkout add test/fixtures
```

## Porting rules (per docs/plan/plan.md §10.1)

- Convert to ESM; drop `test/common` and `node:test`; assert via deterministic
  `console.log` or exit-non-zero checks enforced by `tests/zig/*_test.zig`.
- Skip cases exercising deferred APIs (`*Sync`, streams, watchers).
- Cite the original test filename(s) in a comment at the top of each ported
  fixture; keep the fixture named after its topic (`fs_readfile.js`).
- Fixtures clean up after themselves under `tests/fixtures/.<topic>-work/`.
