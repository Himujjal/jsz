# buffer / encoding fixtures

Ported from the Node.js `test/parallel/test-buffer-*` and
`test-whatwg-encoding-*` suites (snapshot in `tests/fixtures/node/` has no
`buffer` directory, so the upstream sources are the ground truth). All fixtures
are ESM only, print deterministic `console.log` output, and use no `assert` or
`test/common`.

Expected output was generated with real Node and asserted byte-for-byte by
`tests/zig/buffer_test.zig` through `helpers.runFixtureStdout`.

## Covered

| Fixture | Upstream test(s) |
| --- | --- |
| `from.mjs` | `test-buffer-from`, `test-buffer-arraybuffer`, `test-buffer-backing-arraybuffer` |
| `encodings.mjs` | `test-buffer-ascii`, `test-buffer-bytelength`, `test-buffer-hex`, `test-buffer-base64`, `test-buffer-utf16le`, `test-buffer-invalid-utf8` |
| `alloc_concat.mjs` | `test-buffer-alloc`, `test-buffer-concat`, `test-buffer-fill` |
| `methods.mjs` | `test-buffer-slice`, `test-buffer-equals`, `test-buffer-compare`, `test-buffer-indexof`, `test-buffer-copy`, `test-buffer-write`, `test-buffer-tojson` |
| `readwrite.mjs` | `test-buffer-read`, `test-buffer-write`, `test-buffer-readuint`, `test-buffer-float`, `test-buffer-bigint64` |
| `isbuffer.mjs` | `test-buffer-isbuffer`, `test-buffer-constants` |
| `text_encoding.mjs` | `test-whatwg-encoding-*` |
| `atob_btoa.mjs` | `test-buffer-btoa-atob` |
| `globals.mjs` | global `Buffer` identity plus `fs.readFile` returning a real `Buffer` |

## Implementation notes

- `Buffer` is a real `class Buffer extends Uint8Array`; QuickJS preserves the
  prototype through `subarray`/`slice`/`map`/`from`, so no wrapper class is
  needed (the plan's §6.3 spike passes).
- `Buffer.allocUnsafe` returns zero-filled memory. There is no pooling and no
  uninitialized memory, so the "unsafe" contract is weaker than Node's, never
  weaker in the dangerous direction.
- `Buffer.slice` returns a view (`subarray`) like Node, while
  `Uint8Array.prototype.slice` still copies.
- `ascii` encodes like `latin1` and only masks to 7 bits when decoding, matching
  Node (`Buffer.from('é', 'ascii')` is `<e9>`, `Buffer.from([0xe9]).toString('ascii')` is `'i'`).
- Base64 and hex decoders are lenient like Node: invalid characters are skipped,
  a trailing unpaired hex nibble is dropped, and malformed input yields fewer
  bytes instead of throwing.
- `TextDecoder` maps `latin1`/`binary`/`ascii`/`windows-1252` to a byte-per-code-unit
  decoder. Node maps those labels to windows-1252, so bytes in `0x80..0x9f`
  decode to the Latin-1 control range here instead of the windows-1252 glyphs.
- QuickJS has no `DOMException`, so `btoa`/`atob` failure is an `Error` with
  `name = 'InvalidCharacterError'` and `code = 'ERR_INVALID_CHARACTER'`.

## Not ported (deferred)

| Upstream test | Reason |
| --- | --- |
| `test-buffer-alloc-unsafe-is-uninitialized` | jsz never exposes uninitialized memory |
| `test-buffer-bigint64` write-side edge cases | covered partially by `readwrite.mjs` |
| `test-buffer-constructor-*` | `new Buffer(number)` deprecation paths are out of scope |
| `test-buffer-inspect` | needs `util.inspect` (Phase 3B) |
| `test-buffer-pool*` | no pooling |
| `Blob`, `File`, `transcode`, `isUtf8`, `isAscii`, `isLatin1`, `resolveObjectURL` | not in the 90% surface |
| `test-whatwg-encoding-custom-*` | `TextDecoderStream` and legacy labels are out of scope |
