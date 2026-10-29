// Close before listen: Node emits `close` and hands `ERR_SERVER_NOT_RUNNING` to
// the callback instead of silently succeeding; a second close reports the same
// code (the double-close case also appears in test-http-unix-socket.js).

import { createServer } from 'node:http';

const watchdog = setTimeout(() => {
  console.log('timeout');
  process.exit(1);
}, 3000);

const server = createServer((req, res) => {
  res.end('ok');
});

function closeOnce(label) {
  return new Promise((resolve) => {
    server.once('close', () => console.log(`event ${label}`));
    server.close((error) => resolve(error));
  });
}

const never = await closeOnce('never');
console.log(`never ${never === undefined ? 'none' : never.code}`);
console.log(`never-listening ${server.listening} ${server.address() === null}`);

const again = await closeOnce('closed');
console.log(`again ${again === undefined ? 'none' : again.code}`);

await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
console.log(`listening ${server.listening}`);
await new Promise((resolve) => server.close(() => resolve()));
console.log('closed');

const afterRun = await closeOnce('after-run');
console.log(`after-run ${afterRun === undefined ? 'none' : afterRun.code}`);

clearTimeout(watchdog);
