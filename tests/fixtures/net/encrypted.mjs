// Plain TCP sockets report `encrypted === false` on both ends, and the property
// is present instead of undefined.

import net from 'node:net';

const watchdog = setTimeout(() => {
  console.log('timeout');
  process.exit(1);
}, 2000);

let serverFlag = 'missing';

const server = net.createServer((socket) => {
  socket.on('error', () => {});
  serverFlag = `${socket.encrypted} ${'encrypted' in socket}`;
  socket.end('bye');
});

server.on('error', (error) => {
  console.log(`server-error:${error.code}`);
  process.exit(1);
});

server.listen(0, '127.0.0.1', () => {
  const { port } = server.address();
  const client = net.connect(port, '127.0.0.1', () => {
    console.log(`client ${client.encrypted} ${'encrypted' in client}`);
  });

  client.on('error', (error) => {
    console.log(`client-error:${error.code}`);
    process.exit(1);
  });

  client.on('data', () => {});

  client.on('close', () => {
    server.close(() => {
      clearTimeout(watchdog);
      console.log(`server ${serverFlag}`);
      console.log('closed');
    });
  });
});
