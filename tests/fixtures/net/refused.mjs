// Connection refused: bind a port, release it, then dial it again.
//
// Node reports `ECONNREFUSED` as an `error` event followed by `close`.

import net from 'node:net';
import process from 'node:process';

globalThis.__result = '';

const lines = [];
function say(line) {
  lines.push(line);
  globalThis.__result = lines.join('\n');
  console.log(line);
}

const watchdog = setTimeout(() => {
  console.log('timeout');
  process.exit(1);
}, 2000);

const server = net.createServer();
server.on('error', (error) => {
  console.log(`server-error:${error.code}`);
  process.exit(1);
});

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;
  server.close(() => {
    const client = net.connect(port, '127.0.0.1', () => {
      console.log('unexpected-connect');
      process.exit(1);
    });

    client.on('error', (error) => {
      say(`error:${error.code}`);
    });

    client.on('close', (hadError) => {
      clearTimeout(watchdog);
      say(`closed:${hadError}`);
    });
  });
});
