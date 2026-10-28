// Server-side streaming: `res.write` must reach the wire as HTTP chunks
// before `end`, `flushHeaders` commits early, and the status line honours an
// arbitrary numeric code plus `statusMessage`. The raw `node:net` client keeps
// the framing visible so the assertions are on bytes, not on a parsed response.

import { createServer } from 'node:http';
import net from 'node:net';

const watchdog = setTimeout(() => {
  console.log('timeout');
  process.exit(1);
}, 4000);

const server = createServer((req, res) => {
  if (req.url === '/stream') {
    res.setHeader('content-type', 'text/plain');
    res.write('one-');
    setTimeout(() => {
      res.write('two-');
      setTimeout(() => {
        res.write('three');
        res.end();
      }, 30);
    }, 30);
  } else if (req.url === '/status') {
    res.statusCode = 599;
    res.statusMessage = 'Custom Reason';
    res.end('ok');
  } else if (req.url === '/length') {
    res.setHeader('Content-Length', '5');
    res.write('hello');
    res.end();
  } else if (req.url === '/drain') {
    const chunk = 'a'.repeat(128 * 1024);
    const writable = res.write(chunk);
    res.once('drain', () => {
      console.log(`drain ${writable === false}`);
      res.end();
    });
  } else {
    res.statusCode = 404;
    res.end('nope');
  }
});

server.on('error', (error) => {
  console.log(`error ${error.code}`);
  process.exit(1);
});

function rawRequest(port, path) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1');
    const chunks = [];
    socket.on('connect', () => {
      socket.write(`GET ${path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n`);
    });
    socket.on('data', (chunk) => chunks.push(Buffer.from(chunk)));
    socket.on('error', reject);
    socket.on('end', () => resolve(Buffer.concat(chunks).toString('latin1')));
  });
}

function split(raw) {
  const marker = raw.indexOf('\r\n\r\n');
  return { head: raw.slice(0, marker), body: raw.slice(marker + 4) };
}

function decodeChunked(body) {
  let text = '';
  let index = 0;
  while (index < body.length) {
    const lineEnd = body.indexOf('\r\n', index);
    if (lineEnd < 0) break;
    const size = parseInt(body.slice(index, lineEnd), 16);
    if (!Number.isFinite(size) || size === 0) break;
    text += body.slice(lineEnd + 2, lineEnd + 2 + size);
    index = lineEnd + 2 + size + 2;
  }
  return text;
}

function listen() {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(server.address()));
  });
}

function close() {
  return new Promise((resolve) => server.close(() => resolve()));
}

const address = await listen();
const { port } = address;

try {
  const stream = split(await rawRequest(port, '/stream'));
  const chunked = stream.head.toLowerCase().includes('transfer-encoding: chunked');
  console.log(`stream-chunked ${chunked}`);

  const streamBody = decodeChunked(stream.body);
  console.log(`stream-body ${streamBody}`);

  const status = split(await rawRequest(port, '/status'));
  const statusLine = status.head.split('\r\n')[0];
  console.log(`status-line ${statusLine}`);

  const length = split(await rawRequest(port, '/length'));
  console.log(`length-body ${length.body.length}`);
  console.log(`length-chunked ${length.head.toLowerCase().includes('transfer-encoding: chunked')}`);

  const drain = split(await rawRequest(port, '/drain'));
  console.log(`drain-body ${decodeChunked(drain.body).length}`);
} finally {
  clearTimeout(watchdog);
  await close();
  console.log('closed');
}
