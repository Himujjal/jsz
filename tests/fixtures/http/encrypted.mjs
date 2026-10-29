// `socket.encrypted` on plain HTTP: the property exists and is false for both
// the server-side `req.socket` and the client-side `res.socket`.

import { createServer, request } from 'node:http';

const watchdog = setTimeout(() => {
  console.log('timeout');
  process.exit(1);
}, 3000);

let serverFlag;

const server = createServer((req, res) => {
  serverFlag = `${req.socket.encrypted} ${'encrypted' in req.socket}`;
  res.end('ok');
});

server.on('error', (error) => {
  console.log(`error ${error.code}`);
  process.exit(1);
});

await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const { port } = server.address();

const body = await new Promise((resolve, reject) => {
  const req = request({ host: '127.0.0.1', port, path: '/' }, (res) => {
    console.log(`client ${res.socket.encrypted} ${'encrypted' in res.socket}`);
    let text = '';
    res.setEncoding('utf8');
    res.on('data', (chunk) => {
      text += chunk;
    });
    res.on('end', () => resolve(text));
  });
  req.on('error', reject);
  req.end();
});

console.log(`server ${serverFlag}`);
console.log(`body ${body}`);

await new Promise((resolve) => server.close(resolve));
clearTimeout(watchdog);
console.log('closed');
