// End-to-end `node:http` server fixture: the server answers requests issued by
// `fetch`, so it exercises the accept loop, request dispatch, and response
// hand-off. Every printed line is deterministic.

import { createServer } from 'node:http';

const watchdog = setTimeout(() => {
  console.log('timeout');
  process.exit(1);
}, 3000);

const server = createServer((req, res) => {
  const chunks = [];
  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => {
    const body = Buffer.concat(chunks).toString('utf8');
    const header = req.headers['x-test'] === undefined ? 'none' : req.headers['x-test'];
    const text = `${req.method} ${req.url} ${body} ${header}`;

    res.statusCode = req.url === '/echo' ? 201 : 200;
    res.setHeader('x-echo', text);
    res.setHeader('content-type', 'text/plain');
    res.end(text);
  });
});

server.on('error', (error) => {
  console.log(`error ${error.code}`);
  process.exit(1);
});

function listen() {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => resolve(server.address()));
  });
}

function close() {
  return new Promise((resolve) => {
    server.close(() => resolve());
  });
}

const address = await listen();
console.log(`listening ${address.family} ${address.port > 0}`);
const base = `http://127.0.0.1:${address.port}`;

try {
  const echo = await fetch(`${base}/echo`, {
    method: 'POST',
    body: 'hello',
    headers: { 'x-test': 'yes' },
  });
  console.log(`echo ${echo.status} ${echo.headers.get('x-echo')}`);
  console.log(`echo-body ${await echo.text()}`);

  const second = await fetch(`${base}/two`);
  console.log(`second ${second.status} ${await second.text()}`);
} finally {
  clearTimeout(watchdog);
  await close();
  console.log('closed');
}
