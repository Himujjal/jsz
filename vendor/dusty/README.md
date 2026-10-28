# dusty (vendored)

Vendored from [`lalinsky/dusty`](https://github.com/lalinsky/dusty) v0.5.0
(commit `48196c2d81f6cc54f6483b87f56cf808a9d7ba56`) under the MIT license in
[`LICENSE`](./LICENSE).

Local patches, both in service of Node-compatible HTTP status lines:

- `src/response.zig`, `src/http.zig`: `Response` accepts a numeric
  `status_code` and a caller-supplied `status_text`; the status line uses them
  and falls back to a reason-phrase table instead of llhttp's uppercase enum
  names. Body framing (`statusHasBody`) is numeric so an unnamed code works.
- `src/parser.zig`, `src/client.zig`: the response parser keeps the wire status
  code and reason phrase even when `Status` does not name the code, and the
  client exposes `statusCode()`/`statusText()`.

Everything else is upstream v0.5.0. Update this directory by re-copying the
upstream package and re-applying the two patches; keep the tests in
`src/parser.zig` aligned with the second patch.
