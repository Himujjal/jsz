// `https.createServer` with a PEM certificate/key. This fixture only proves
// the TLS listener binds and closes; the handshake path is covered by dusty.

import https from 'node:https';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const watchdog = setTimeout(() => {
  console.log('timeout');
  process.exit(1);
}, 3000);

const cert = await readFile(fileURLToPath(new URL('cert.pem', import.meta.url)), 'utf8');
const key = await readFile(fileURLToPath(new URL('key.pem', import.meta.url)), 'utf8');

const server = https.createServer({ cert, key }, (req, res) => {
  res.end('secure');
});

server.on('error', (error) => {
  console.log(`error ${error.code}`);
  process.exit(1);
});

server.listen(0, '127.0.0.1', () => {
  const address = server.address();
  console.log(`listening ${address.family} ${address.port > 0}`);
  console.log(`server ${server instanceof https.Server}`);
  server.close(() => {
    clearTimeout(watchdog);
    console.log('closed');
  });
});
