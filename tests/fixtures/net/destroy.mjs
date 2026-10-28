// `destroy` tears down a connecting and an established socket immediately.
//
// The connecting case destroys in the same turn as `connect`, so the connect
// event cannot have settled yet; the fixture can assert it never fires.

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

const server = net.createServer((socket) => {
  socket.on('error', () => {});
});

server.on('error', (error) => {
  console.log(`server-error:${error.code}`);
  process.exit(1);
});

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;

  const pending = net.connect(port, '127.0.0.1');
  let pendingConnected = false;
  pending.on('connect', () => {
    pendingConnected = true;
    say('unexpected-connect');
  });
  pending.on('error', (error) => {
    say(`pending-error:${error.code}`);
  });
  pending.on('close', (hadError) => {
    say(`pending-closed:${hadError}:${pendingConnected}`);

    const client = net.connect(port, '127.0.0.1', () => {
      say('connected');
      client.destroy();
    });
    client.on('error', (error) => {
      say(`client-error:${error.code}`);
    });
    client.on('close', (closeHadError) => {
      say(`closed:${closeHadError}`);
      clearTimeout(watchdog);
      server.close(() => say('server-closed'));
    });
  });

  pending.destroy();
});
