// Exits while the dusty listener and its accept task are still live. The
// runtime teardown must cancel the server without touching freed memory.
import { createServer } from 'node:http';

const server = createServer((req, res) => res.end('ok'));
server.listen(0, '127.0.0.1', () => {
  console.log('start');
  process.exit(0);
});
