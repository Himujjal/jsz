# Roadmap

This page records what ships today, the intentional exclusions, and the next
steps. The next steps are ideas, not commitments, and the order is approximate.
For runnable commands see the [CLI](cli.md); for packaging and desktop assets
see [single-executable apps](single-executable.md). The older
[compatibility plan](plan/plan.md) preserves historical design decisions and
should not be read as a current feature inventory.

## Shipped

- [x] `console` (formatting, `dir`, `trace`, `assert`, `time`/`timeEnd`),
      timers, `sleep(ms)`, and native QuickJS Promises
- [x] `performance` (`now`, `timeOrigin`), `global`, and `queueMicrotask`
- [x] ESM `import`/`export`, `node:` and bare builtin specifiers, `import.meta`,
      dynamic `import()`, and extension/index probing
- [x] Async `fs` and `fs/promises`: read/write/append, copy/cp, rename, rm,
      mkdir/mkdtemp, readdir (including `recursive: true`), stat/lstat/fstat,
      access, realpath, links, chmod/chown/utimes, and descriptor APIs
      (`open`/`read`/`write`/`close`/`fsync`/`ftruncate`, `FileHandle`)
- [x] `fs` fidelity: numeric `O_*` flags, `dest` on two-path errors,
      `Dirent.parentPath`, and `Stats.blksize`
- [x] `process`, `os`, `crypto`, `path` (posix + win32), `url`, `util`, `events`,
      `Buffer`, `TextEncoder`/`TextDecoder`, `atob`/`btoa`
- [x] `process` signals: SIGINT, SIGTERM, and SIGHUP listeners plus Node's
      default `128+signum` exit codes
- [x] `child_process` sync and async `spawn`/`exec`/`execFile`, output streams,
      stdin, signals, `timeout`, and `AbortSignal`
- [x] TCP `node:net` servers and clients
- [x] `http.createServer` over vendored dusty 0.5.0: `res.write` and
      `flushHeaders` send real chunks, `end` terminates or sends a single
      buffered body, a 64 KiB high-water queue drives `drain`, `destroy`
      aborts, headers are immutable after send, and `statusMessage` plus
      arbitrary 100-999 status codes reach the wire. `server.close()` drains
      in-flight responses.
- [x] `http.request`/`http.get` and `https.request`/`https.get` with response
      bodies streamed through `IncomingMessage` `data`/`end`/`close` and
      ack-based pause/resume backpressure
- [x] `https.request`/`https.get` TLS options: `ca`, `cert`+`key`,
      `pfx`+`passphrase`, and `rejectUnauthorized`; each distinct TLS
      configuration gets its own cached client and connection pool
- [x] `https.createServer` over dusty's TLS listener with PEM `cert`/`key`,
      `pfx`+`passphrase`, `ca`, `requestCert`, and `rejectUnauthorized` (mTLS)
- [x] Global `fetch`/`Headers`/`Response`/`Request` over vendored dusty 0.5.0
      with redirects, final URLs, `redirect: 'error' | 'manual'`, decompression,
      HTTPS, and in-flight `AbortSignal` cancellation
- [x] Runtime hardening: job-queue accounting guards, no `unreachable` on
      unexpected stream events, `ERR_SERVER_NOT_RUNNING`, and `socket.encrypted`
      on HTTP, HTTPS, and TCP sockets
- [x] Zig integration tests, JavaScript fixtures, optional differential tests
      against a local `node`, mise tasks, hk pre-commit checks, and Forgejo
      Actions CI

## Deferred (the last 10%)

- Full Node streams (`Readable`/`Writable`, web streams)
- Streaming `fetch` response bodies (`res.text()`/`json()` stay buffered)
- HTTP request-body streaming (server bodies are capped at 1 MiB), trailers,
  and interim 1xx responses
- `dns`, `tls`, `zlib`, `worker_threads`, `readline`, `assert`
- `fs.watch`, `fs.createReadStream`/`createWriteStream`, `fs` `*Sync`
- UDP (`node:dgram`)
- `child_process.fork` and Node-compatible IPC
- `webcrypto.subtle`, ciphers, key generation, signing

## Known limitations

- JavaScript is single-threaded. QuickJS is touched only on the JS task; zio
  tasks carry file, child, network, and fetch work.
- `fs` is async-only. `*Sync` names throw `ERR_METHOD_NOT_IMPLEMENTED`, and
  `existsSync` is not exported. `fs.opendir` is not implemented.
- Numeric `O_*` flags are translated to the supported string flags.
  `O_SYNC`/`O_DSYNC` are accepted in a mask but not honored, and append uses a
  stat-then-write rather than an atomic `O_APPEND`.
- `Stats.uid`, `gid`, `dev`, and `rdev` are `0` (`std.Io.File.Stat` does not
  expose them), `birthtime` falls back to `ctime`, and `blocks` is derived from
  the size.
- HTTP request bodies are buffered whole (1 MiB cap), so handlers cannot read
  `req` incrementally. Response bodies stream. `fetch` responses are buffered
  and capped at 10 MiB.
- `IncomingMessage` is not a full `Readable`: it emits `data`/`end`/`close`,
  supports `setEncoding`, `pause`, `resume`, and `destroy`, but not `read`,
  `pipe`, `unshift`, or async iteration. Reads are 16 KiB, so bodies under
  16 KiB arrive as a single `data` event. `res.complete` is false until EOF.
- `http.request`/`http.get`/`https.request`/`https.get` do not follow
  redirects. `socket.encrypted` is set on server requests and client responses
  (`true` over TLS, `false` over plain TCP/HTTP).
- `https` accepts `servername` but ignores it; dusty derives the SNI name from
  the URL. There is no per-request SNI override.
- `https.createServer` accepts PEM `cert`/`key`, `pfx`+`passphrase`, `ca`,
  `requestCert`, and `rejectUnauthorized`. PFX parsing is pure Zig (PBES2/AES
  and legacy SHA1+3DES/RC2 PBE); MAC verification, RC4 PFX, and non-AES PBES2
  schemes are rejected.
- The status line and response parser come from vendored dusty
  (`vendor/dusty`) with a small patch: servers can emit a numeric status code
  with a caller-supplied reason phrase, and the client parser accepts codes its
  `Status` enum does not name. `fetch` reason phrases still come from dusty's
  parser, so HTTP/2 responses do not carry the wire reason phrase.
- `http.Server.close()` stops accepting, lets in-flight handlers finish, and
  closes idle keep-alive connections through dusty's drain. `net.Server.close()`
  stops accepting but does not wait for accepted sockets. Closing either before
  `listen()` reports `ERR_SERVER_NOT_RUNNING`.
- Unhandled promise rejections print `UnhandledPromiseRejectionWarning` and exit
  `1`; Node 22 throws `ERR_UNHANDLED_REJECTION` by default.
- `fetch` supports in-flight `AbortSignal` cancellation; an already-aborted
  signal rejects before the request starts.
- Timer delays are clamped to 2,147,483,647 ms.
- No source maps. Stack traces refer to the evaluated source without a mapping
  layer.

## Possible next steps

1. **Streams.** Implement `Readable`/`Writable` and move HTTP request/response
   bodies, `net.Socket`, and child-process stdio onto them.
2. **Fetch streaming.** Expose the response body as a stream and stream request
   bodies instead of buffering them.
3. **HTTP request streaming.** Read server request bodies incrementally, add
   trailers, and handle interim 1xx responses.
4. **Remaining fidelity.** Port the `errno` table to `std.posix.E`, add
   `fs.opendir`, `cp` `preserveTimestamps`, `process.stdin`, the `os` counters
   that need libc, Node-22 unhandled-rejection semantics, and more Node test
   ports (the differential harness is in place).
5. **Worker threads.** Run JavaScript on multiple threads with one QuickJS
   context per worker and message passing.
