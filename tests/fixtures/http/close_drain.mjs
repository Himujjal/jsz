// `server.close()` stops accepting but lets an in-flight handler finish before
// the close callback runs. The delayed response would be replaced by 503 if the
// connection were torn down eagerly.

import { createServer } from 'node:http';

const watchdog = setTimeout(() => {
  console.log('timeout');
  process.exit(1);
}, 3000);

let requestStarted;
const started = new Promise((resolve) => {
  requestStarted = resolve;
});

const server = createServer((req, res) => {
  requestStarted();
  setTimeout(() => {
    res.statusCode = 200;
    res.end('drained');
  }, 100);
});

server.on('error', (error) => {
  console.log(`error ${error.code}`);
  process.exit(1);
});

server.listen(0, '127.0.0.1', async () => {
  const { port } = server.address();
  const pending = fetch(`http://127.0.0.1:${port}/slow`);
  await started;

  const closed = new Promise((resolve) => server.close(() => resolve()));
  const response = await pending;
  console.log(`body ${await response.text()}`);
  await closed;

  clearTimeout(watchdog);
  console.log('closed');
});
