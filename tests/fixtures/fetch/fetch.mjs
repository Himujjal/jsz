// End-to-end `fetch` fixture: exercises the native client against a local
// `node:http` server. Printed lines are deterministic so a harness can compare
// them once the http lane lands.

import { createServer } from 'node:http';

const watchdog = setTimeout(() => {
  console.log('timeout');
  process.exit(1);
}, 3000);

const server = createServer((req, res) => {
  const url = req.url;

  if (url === '/text') {
    res.writeHead(200, { 'content-type': 'text/plain', 'x-test': 'hello' });
    res.end('hello fetch');
    return;
  }

  if (url === '/json') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"ok":true,"count":2}');
    return;
  }

  if (url === '/echo') {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      res.writeHead(200, { 'content-type': 'text/plain' });
      res.end(Buffer.concat(chunks).toString('utf8'));
    });
    return;
  }

  if (url === '/status') {
    res.statusCode = 599;
    res.statusMessage = 'Custom Reason';
    res.end('weird');
    return;
  }

  if (url === '/redirect') {
    res.writeHead(302, { location: '/text' });
    res.end('moved');
    return;
  }

  res.writeHead(404, { 'content-type': 'text/plain' });
  res.end('not found');
});

function listen() {
  return new Promise((resolve, reject) => {
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => resolve(server.address()));
  });
}

function close() {
  return new Promise((resolve) => {
    server.close(() => resolve());
  });
}

const address = await listen();
const port = address !== null && typeof address === 'object' ? address.port : address;
const base = `http://127.0.0.1:${port}`;

try {
  const text = await fetch(`${base}/text`);
  const textBody = await text.text();
  console.log(`text=${text.status} ${textBody}`);

  const json = await fetch(`${base}/json`);
  const parsed = await json.json();
  console.log(`json=${parsed.ok} ${parsed.count}`);

  const echo = await fetch(`${base}/echo`, {
    method: 'POST',
    body: 'payload-42',
  });
  console.log(`echo=${await echo.text()}`);

  const headers = new Headers(text.headers);
  console.log(`header=x-test:${headers.get('x-test')}`);

  const missing = await fetch(`${base}/missing`);
  console.log(`missing=${missing.status} ${await missing.text()}`);

  const unusual = await fetch(`${base}/status`);
  console.log(`status=${unusual.status} ${unusual.statusText} ${await unusual.text()}`);

  const redirect = await fetch(`${base}/redirect`, { redirect: 'follow' });
  console.log(`redirect=${redirect.status} ${await redirect.text()}`);
} finally {
  clearTimeout(watchdog);
  await close();
}
