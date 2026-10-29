// `socket.encrypted` over TLS: true on the server's `req.socket` and on the
// client's `res.socket`, with the property present on both.

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

let serverFlag;

const server = https.createServer({ cert, key }, (req, res) => {
  serverFlag = `${req.socket.encrypted} ${'encrypted' in req.socket}`;
  res.end('ok');
});

server.on('error', (error) => {
  console.log(`error ${error.code}`);
  process.exit(1);
});

await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const { port } = server.address();

const body = await new Promise((resolve, reject) => {
  const req = https.request({ host: '127.0.0.1', port, path: '/', ca }, (res) => {
    console.log(`client ${res.socket.encrypted} ${'encrypted' in res.socket}`);
    let text = '';
    res.setEncoding('utf8');
    res.on('data', (chunk) => {
      text += chunk;
    });
    res.on('end', () => resolve(text));
  });
  req.on('error', reject);
  req.end();
});

console.log(`server ${serverFlag}`);
console.log(`body ${body}`);

await new Promise((resolve) => server.close(resolve));
clearTimeout(watchdog);
console.log('closed');
