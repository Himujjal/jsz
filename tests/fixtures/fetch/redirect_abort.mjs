// Redirect modes, final response URLs, and in-flight AbortSignal handling.

import { createServer } from 'node:http';

const watchdog = setTimeout(() => {
  console.log('timeout');
  process.exit(1);
}, 3000);

const server = createServer((req, res) => {
  if (req.url === '/redirect') {
    res.writeHead(302, { location: '/text' });
    res.end('moved');
    return;
  }
  if (req.url === '/slow') {
    setTimeout(() => res.end('late'), 500);
    return;
  }
  res.writeHead(200, { 'content-type': 'text/plain' });
  res.end('text');
});

server.on('error', (error) => {
  console.log(`error ${error.code}`);
  process.exit(1);
});

server.listen(0, '127.0.0.1', async () => {
  const { port } = server.address();
  const base = `http://127.0.0.1:${port}`;

  const followed = await fetch(`${base}/redirect`);
  console.log(`followed ${followed.status} ${followed.url === `${base}/text`} ${followed.redirected}`);

  try {
    await fetch(`${base}/redirect`, { redirect: 'error' });
    console.log('error-mode none');
  } catch (error) {
    console.log(`error-mode ${error.code}`);
  }

  const manual = await fetch(`${base}/redirect`, { redirect: 'manual' });
  console.log(`manual ${manual.status} ${manual.headers.get('location')}`);

  const controller = new AbortController();
  const pending = fetch(`${base}/slow`, { signal: controller.signal });
  setTimeout(() => controller.abort(), 20);
  try {
    await pending;
    console.log('abort none');
  } catch (error) {
    console.log(`abort ${error.name} ${error.code}`);
  }

  server.close(() => {
    clearTimeout(watchdog);
    console.log('closed');
  });
});
