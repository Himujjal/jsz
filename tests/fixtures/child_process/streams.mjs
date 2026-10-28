// Deterministic coverage of stdout/stderr flow control: bounded native reads,
// pause/resume, pipe, and async iteration. Absolute tools only.
import { spawn } from 'node:child_process';
import { EventEmitter } from 'node:events';

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function waitClose(child) {
  return new Promise((resolve) => {
    child.on('close', (code, signal) => resolve({ code, signal }));
  });
}

function bufferedBytes(stream) {
  return stream._buffered.reduce((sum, chunk) => sum + chunk.length, 0);
}

{
  const child = spawn('/bin/sh', ['-c', 'dd if=/dev/zero bs=1024 count=2048 2>/dev/null']);
  let emitted = 0;
  child.stdout.on('data', (chunk) => {
    emitted += chunk.length;
  });
  child.stdout.pause();
  const closed = waitClose(child);

  await sleep(100);
  const beforeResume = emitted + bufferedBytes(child.stdout);
  const bounded = beforeResume < 512 * 1024;

  child.stdout.resume();
  await closed;

  const total = emitted + bufferedBytes(child.stdout);
  console.log(`pause=${bounded ? 'pass' : `fail(${beforeResume})`}:${total}`);
}

{
  const child = spawn('/bin/sh', ['-c', 'printf hello']);
  let piped = '';
  child.stdout.pipe({
    write(chunk) {
      piped += chunk.toString();
      return true;
    },
  });
  await waitClose(child);
  console.log(`pipe=${piped}`);
}

{
  const child = spawn('/bin/sh', ['-c', 'printf backpressure']);
  const dest = new EventEmitter();
  let received = '';
  let first = true;
  dest.write = (chunk) => {
    received += chunk.toString();
    if (first) {
      first = false;
      setTimeout(() => dest.emit('drain'), 10);
      return false;
    }
    return true;
  };
  dest.end = () => {};

  child.stdout.pipe(dest);
  await waitClose(child);
  console.log(`pipe-drain=${received}`);
}

{
  const child = spawn('/bin/sh', ['-c', 'printf iter']);
  let total = 0;
  for await (const chunk of child.stdout) total += chunk.length;
  console.log(`iterator=${total}`);
}

{
  const child = spawn('/bin/sh', ['-c', 'printf closed']);
  child.stdout.resume();
  await waitClose(child);
  console.log(`closed=${child.stdout.readable}:${child.stdout.destroyed}`);
}

{
  const child = spawn('/bin/sh', ['-c', 'printf err >&2']);
  let stderr = '';
  child.stderr.on('data', (chunk) => {
    stderr += chunk.toString();
  });
  child.stderr.pause();
  const closed = waitClose(child);

  await sleep(50);
  child.stderr.resume();
  await closed;
  console.log(`stderr=${stderr}`);
}
