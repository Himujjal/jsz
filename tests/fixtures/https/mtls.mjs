// HTTPS server options beyond PEM cert/key: mutual TLS, PFX certificates, and
// a client PFX. The certificates are a local CA, a server leaf with a
// 127.0.0.1 SAN, and a client leaf signed by the same CA.

import https from 'node:https';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const watchdog = setTimeout(() => {
  console.log('timeout');
  process.exit(1);
}, 5000);

function fixture(name) {
  return readFile(fileURLToPath(new URL(name, import.meta.url)));
}

const [ca, cert, key, clientCert, clientKey, clientPfx] = await Promise.all([
  fixture('ca.pem'),
  fixture('server.pem'),
  fixture('server-key.pem'),
  fixture('client.pem'),
  fixture('client-key.pem'),
  fixture('client.p12'),
]);
const pfx = await fixture('pfx.p12');

function handler(req, res) {
  res.setHeader('content-type', 'text/plain');
  res.end('secure');
}

const mtls = https.createServer(
  { cert, key, ca, requestCert: true, rejectUnauthorized: true },
  handler,
);
const pfxServer = https.createServer({ pfx, passphrase: 'jsz' }, handler);

for (const server of [mtls, pfxServer]) {
  server.on('error', (error) => {
    console.log(`error ${error.code}`);
    process.exit(1);
  });
}

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(server.address()));
  });
}

function readResponse(res) {
  return new Promise((resolve, reject) => {
    let body = '';
    res.setEncoding('utf8');
    res.on('data', (chunk) => {
      body += chunk;
    });
    res.on('end', () => resolve(body));
    res.on('error', reject);
  });
}

function request(port, options = {}) {
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        host: '127.0.0.1',
        port,
        path: '/',
        ...options,
      },
      (res) => {
        readResponse(res).then((body) => resolve({ status: res.statusCode, body })).catch(reject);
      },
    );
    req.on('error', reject);
    req.end();
  });
}

const mtlsAddress = await listen(mtls);
const pfxAddress = await listen(pfxServer);

try {
  const direct = await request(mtlsAddress.port, { ca, cert: clientCert, key: clientKey });
  console.log(`mtls ${direct.status} ${direct.body}`);

  const arrayCa = await request(mtlsAddress.port, { ca: [ca], cert: clientCert, key: clientKey });
  console.log(`mtls-ca-array ${arrayCa.status} ${arrayCa.body}`);

  const viaPfx = await request(mtlsAddress.port, { ca, pfx: clientPfx, passphrase: 'jsz' });
  console.log(`mtls-pfx ${viaPfx.status} ${viaPfx.body}`);

  try {
    await request(mtlsAddress.port, { ca });
    console.log('mtls-missing false');
  } catch {
    console.log('mtls-missing true');
  }

  const fromPfx = await request(pfxAddress.port, { rejectUnauthorized: false });
  console.log(`pfx-server ${fromPfx.status} ${fromPfx.body}`);

  let wrong = 'none';
  try {
    https.createServer({ pfx, passphrase: 'not-jsz' });
  } catch (error) {
    wrong = error.code;
  }
  console.log(`pfx-wrong ${wrong}`);
} finally {
  clearTimeout(watchdog);
  await Promise.all([
    new Promise((resolve) => mtls.close(resolve)),
    new Promise((resolve) => pfxServer.close(resolve)),
  ]);
  console.log('closed');
}
