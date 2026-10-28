// Deterministic coverage of non-blocking child stdin: no data loss, drain
// backpressure, and writable state after end. Absolute tools only.
import { spawn } from 'node:child_process';

function waitClose(child) {
  return new Promise((resolve) => {
    child.on('close', (code, signal) => resolve({ code, signal }));
  });
}

{
  const child = spawn('/bin/cat');
  let stdout = '';
  child.stdout.on('data', (chunk) => {
    stdout += chunk.toString();
  });
  const closed = waitClose(child);
  const accepted = child.stdin.write('abc');
  child.stdin.end();
  await closed;
  console.log(`small=${accepted}:${stdout}`);
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

{
  const child = spawn('/bin/cat');
  let length = 0;
  child.stdout.on('data', (chunk) => {
    length += chunk.length;
  });
  const closed = waitClose(child);
  const accepted = child.stdin.write(Buffer.alloc(1024 * 1024, 'b'));
  await new Promise((resolve) => child.stdin.once('drain', resolve));
  child.stdin.end();
  await closed;
  console.log(`huge=${accepted}:${length}`);
}

{
  const child = spawn('/bin/cat');
  const closed = waitClose(child);
  child.stdin.end();
  console.log(`writable=${child.stdin.writable}`);
  const after = child.stdin.write('x');
  console.log(`after-end=${after}`);
  await closed;
}
