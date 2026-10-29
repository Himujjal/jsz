// `net.Server.close()` before `listen()` reports ERR_SERVER_NOT_RUNNING through
// the callback, matching Node and the http server path.

import net from 'node:net';

const watchdog = setTimeout(() => {
  console.log('timeout');
  process.exit(1);
}, 2000);

const server = net.createServer();

const error = await new Promise((resolve) => {
  server.close((failure) => resolve(failure));
});

console.log(`code ${error === undefined ? 'none' : error.code}`);
console.log(`listening ${server.listening} address ${server.address()}`);

clearTimeout(watchdog);
