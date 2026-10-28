// Shutdown with a live listener and socket: `process.exit` must tear the zio
// tasks down without leaking records, dispatches, or queued writes.

import net from 'node:net';
import process from 'node:process';

globalThis.__result = '';

console.log('start');

const server = net.createServer((socket) => {
  socket.on('error', () => {});
  socket.on('data', () => {});
});

server.on('error', (error) => {
  console.log(`server-error:${error.code}`);
  process.exit(1);
});

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;
  const client = net.connect(port, '127.0.0.1', () => {
    client.write('queued');
    setTimeout(() => {
      console.log('exit-with-live-handles');
      process.exit(0);
    }, 100);
  });
  client.on('error', () => {});
});

setTimeout(() => {
  console.log('timeout');
  process.exit(1);
}, 2000);
