// `http.request` and `http.get` against a local server. The native client is
// buffered: the request body is collected until `end`, and the response body is
// replayed through `data`/`end`.

import { createServer } from 'node:http';
import { get, request } from 'node:http';

const watchdog = setTimeout(() => {
  console.log('timeout');
  process.exit(1);
}, 3000);

const server = createServer((req, res) => {
  const chunks = [];
  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => {
    const body = Buffer.concat(chunks).toString('utf8');
    res.setHeader('x-method', req.method);
    res.end(`${req.url}:${body}`);
  });
});

server.on('error', (error) => {
  console.log(`error ${error.code}`);
  process.exit(1);
});

function readResponse(res) {
  return new Promise((resolve) => {
    let body = '';
    res.setEncoding('utf8');
    res.on('data', (chunk) => {
      body += chunk;
    });
    res.on('end', () => resolve(body));
  });
}

server.listen(0, '127.0.0.1', async () => {
  const { port } = server.address();

  const post = new Promise((resolve, reject) => {
    const req = request(
      {
        host: '127.0.0.1',
        port,
        path: '/echo',
        method: 'POST',
        headers: { 'x-test': 'yes' },
      },
      (res) => {
        const method = res.headers['x-method'];
        readResponse(res).then((body) => resolve(`${res.statusCode} ${method} ${body}`));
      },
    );
    req.on('error', reject);
    req.write('hello ');
    req.end('world');
  });

  const getBody = await new Promise((resolve, reject) => {
    const req = get(`http://127.0.0.1:${port}/get`, (res) => {
      readResponse(res).then(resolve);
    });
    req.on('error', reject);
  });

  console.log(await post);
  console.log(getBody);

  server.close(() => {
    clearTimeout(watchdog);
    console.log('closed');
  });
});
