// TCP echo round-trip: bind on port 0, connect, write `ping`, read the echo.
//
// Prints deterministic lines so the Zig fixture test can assert on stdout.
// The watchdog keeps the fixture from hanging if a socket event never fires.

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
  socket.on('data', (chunk) => {
    socket.write(chunk);
  });
});

server.on('error', (error) => {
  console.log(`server-error:${error.code}`);
  process.exit(1);
});

server.listen(0, '127.0.0.1', () => {
  const { port, address } = server.address();
  if (address !== '127.0.0.1' || port === 0) {
    console.log('bad-address');
    process.exit(1);
    return;
  }

  const client = net.connect(port, '127.0.0.1', () => {
    say('connected');
  });

  let echoed = '';
  client.setEncoding('utf8');

  client.on('data', (chunk) => {
    echoed += chunk;
    if (echoed !== 'ping') return;
    say('echo:ping');
    client.end();
  });

  client.on('error', (error) => {
    console.log(`client-error:${error.code}`);
    process.exit(1);
  });

  client.on('close', () => {
    server.close(() => {
      clearTimeout(watchdog);
      say('server-closed');
    });
  });

  client.write('ping');
});
