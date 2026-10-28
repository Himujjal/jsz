# HTTPS test material

Everything here is test-only. The private keys are intentionally committed so
the fixtures are reproducible; do not reuse them anywhere else.

| File | Purpose |
| --- | --- |
| `cert.pem`, `key.pem` | Original self-signed `CN=localhost` pair used by `server.mjs`. |
| `ca.pem`, `ca-key.pem` | Test CA for the verified handshake and mTLS fixtures. |
| `server.pem`, `server-key.pem` | Leaf for `127.0.0.1`/`localhost` signed by the test CA. |
| `client.pem`, `client-key.pem` | Client leaf signed by the test CA. |
| `client.p12` | `client.pem`/`client-key.pem` exported as PKCS#12, passphrase `jsz`. |
| `pfx.p12` | `cert.pem`/`key.pem` exported with PBES2/AES-256-CBC, passphrase `jsz`. |
| `legacy.p12` | `cert.pem`/`key.pem` exported with LibreSSL's legacy SHA1+3DES/RC2 PBE, passphrase `jsz`. |

Generation notes:

```sh
# Verified chain: CA, server leaf (SAN 127.0.0.1 + localhost), client leaf.
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca-key.pem -out ca.pem \
  -days 3650 -subj "/CN=jsz-test-ca"
# ... server.csr/client.csr signed by ca.pem with the SAN/clientAuth extensions.

# Modern PFX (OpenSSL 3.x):
openssl pkcs12 -export -in cert.pem -inkey key.pem -out pfx.p12 \
  -passout pass:jsz -name jsz \
  -keypbe AES-256-CBC -certpbe AES-256-CBC -macalg SHA256

# Legacy PFX (LibreSSL/OpenSSL default):
openssl pkcs12 -export -in cert.pem -inkey key.pem -out legacy.p12 \
  -passout pass:jsz -name jsz
```
