// stdin write-callback ordering and drain backpressure. The data-correctness
// cases live in stdin.mjs; this fixture keeps the callback/drain contract.
import { spawn } from 'node:child_process';

function waitClose(child) {
  return new Promise((resolve) => {
    child.on('close', (code, signal) => resolve({ code, signal }));
  });
}

{
  const child = spawn('/bin/cat');
  let returned = false;
  child.stdin.write('abc', () => {
    console.log(`callback=${returned}`);
  });
  returned = true;

  let stdout = '';
  child.stdout.on('data', (chunk) => {
    stdout += chunk.toString();
  });
  const closed = waitClose(child);
  child.stdin.end();
  await closed;
  console.log(`stdin=${stdout}`);
}

{
  const child = spawn('/bin/cat');
  let length = 0;
  child.stdout.on('data', (chunk) => {
    length += chunk.length;
  });
  const closed = waitClose(child);
  const accepted = child.stdin.write(Buffer.alloc(200 * 1024, 'a'));
  await new Promise((resolve) => child.stdin.once('drain', resolve));
  child.stdin.end();
  await closed;
  console.log(`large=${accepted}:${length}`);
}
