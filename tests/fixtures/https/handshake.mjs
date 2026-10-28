// `https.request` against a local TLS server: a private CA verifies the
// certificate, the body arrives incrementally, and `rejectUnauthorized: false`
// skips verification. The last case proves verification is not a no-op.
//
// The native stream reads up to 16 KiB per `ack`, so a 3-byte body can only be
// one `data` event; `/bulk` exceeds that buffer to prove chunks really arrive
// one read at a time instead of being replayed whole.

import https from 'node:https';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const watchdog = setTimeout(() => {
  console.log('timeout');
  process.exit(1);
}, 5000);

const cert = await readFile(fileURLToPath(new URL('server.pem', import.meta.url)), 'utf8');
const key = await readFile(fileURLToPath(new URL('server-key.pem', import.meta.url)), 'utf8');
const ca = await readFile(fileURLToPath(new URL('ca.pem', import.meta.url)), 'utf8');

const PART = 8 * 1024;

function writeParts(res, parts) {
  res.write(parts[0]);
  if (parts.length === 1) {
    res.end();
    return;
  }
  setTimeout(() => writeParts(res, parts.slice(1)), 30);
}

const server = https.createServer({ cert, key }, (req, res) => {
  if (req.url === '/chunks') {
    writeParts(res, ['a', 'b', 'c']);
  } else if (req.url === '/bulk') {
    writeParts(res, ['a'.repeat(PART), 'b'.repeat(PART), 'c'.repeat(PART)]);
  } else {
    res.end('secure');
  }
});

server.on('error', (error) => {
  console.log(`error ${error.code}`);
  process.exit(1);
});

function readBody(res) {
  return new Promise((resolve) => {
    let body = '';
    res.setEncoding('utf8');
    res.on('data', (chunk) => {
      body += chunk;
    });
    res.on('end', () => resolve(body));
  });
}

function requestBody(port, path, options) {
  return new Promise((resolve, reject) => {
    const req = https.request({ host: '127.0.0.1', port, path, ...options }, (res) => {
      readBody(res).then((body) => resolve({ status: res.statusCode, body }));
    });
    req.on('error', reject);
    req.end();
  });
}

function requestChunks(port, path) {
  return new Promise((resolve, reject) => {
    const req = https.request({ host: '127.0.0.1', port, path, ca }, (res) => {
      let chunks = 0;
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => {
        chunks += 1;
        body += chunk;
      });
      res.on('end', () => resolve({ status: res.statusCode, body, chunks }));
    });
    req.on('error', reject);
    req.end();
  });
}

await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const { port } = server.address();

try {
  const secure = await requestBody(port, '/', { ca });
  console.log(`secure ${secure.status} ${secure.body}`);

  const streamed = await requestChunks(port, '/chunks');
  console.log(`stream ${streamed.status} ${streamed.body}`);

  const bulk = await requestChunks(port, '/bulk');
  console.log(`bulk ${bulk.status} ${bulk.body.length} ${bulk.chunks >= 2}`);

  const insecure = await requestBody(port, '/', { rejectUnauthorized: false });
  console.log(`insecure ${insecure.status} ${insecure.body}`);
} finally {
  await new Promise((resolve) => server.close(resolve));
  clearTimeout(watchdog);
  console.log('closed');
}
