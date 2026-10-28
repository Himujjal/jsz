// Deterministic coverage of timeout/killSignal/AbortSignal, signal validation,
// per-stream maxBuffer, and spawn option pass-through. Absolute tools only.
import { spawn, spawnSync, exec } from 'node:child_process';

function waitClose(child) {
  return new Promise((resolve) => {
    child.on('close', (code, signal) => resolve({ code, signal }));
  });
}

{
  const child = spawn('/bin/sleep', ['30'], { timeout: 30, killSignal: 'SIGKILL' });
  const result = await waitClose(child);
  console.log(`timeout=${result.signal}`);
}

{
  const result = spawnSync('/bin/sleep', ['30'], { timeout: 30, killSignal: 'SIGKILL' });
  console.log(`timeout-sync=${result.error.code}:${result.signal}`);
}

{
  const controller = new AbortController();
  const child = spawn('/bin/sleep', ['30'], { signal: controller.signal });
  setTimeout(() => controller.abort(), 20);
  const result = await waitClose(child);
  console.log(`abort=${result.signal}`);
}

{
  const controller = new AbortController();
  controller.abort();
  const child = spawn('/bin/echo', ['x'], { signal: controller.signal });
  const code = await new Promise((resolve) => {
    child.on('error', (error) => resolve(error.code));
  });
  console.log(`pre-abort=${code}`);
}

{
  const child = spawn('/bin/sleep', ['30'], { signal: AbortSignal.timeout(20) });
  const result = await waitClose(child);
  console.log(`signal-timeout=${result.signal}`);
}

{
  const child = spawn('/bin/sleep', ['5']);
  let code = null;
  try {
    child.kill('SIGBOGUS');
  } catch (error) {
    code = error.code;
  }
  child.kill('SIGKILL');
  await waitClose(child);
  console.log(`unknown-signal=${code}`);
}

{
  const child = spawn('/bin/sleep', ['5']);
  const running = child.kill(0);
  child.kill('SIGKILL');
  await waitClose(child);
  console.log(`kill-zero=${running}:${child.kill(0)}`);
}

{
  const line = 'i=0; while [ $i -lt 100 ]; do printf 0123456789; i=$((i+1)); done';
  const error = await new Promise((resolve) => {
    exec(`${line}; ${line} >&2`, { maxBuffer: 1500 }, (failure) => resolve(failure));
  });
  console.log(`per-stream=${error === null ? 'ok' : error.code}`);
}

{
  const result = spawnSync('/bin/sh', ['-c', 'printf opt'], { windowsHide: true, detached: true });
  console.log(`options=${result.status}:${result.stdout.toString()}`);
}

{
  const parent = spawnSync('/bin/ps', ['-o', 'pgid=', '-p', String(process.pid)]);
  const child = spawnSync('/bin/sh', ['-c', '/bin/ps -o pgid= -p $$'], { detached: true });
  const childPgid = child.stdout.toString().trim();
  const parentPgid = parent.stdout.toString().trim();
  console.log(`detached=${childPgid !== '' && childPgid !== parentPgid}`);
}

if (typeof process.getuid === 'function') {
  const result = spawnSync('/bin/sh', ['-c', 'printf id'], {
    uid: process.getuid(),
    gid: process.getgid(),
  });
  console.log(`ids=${result.status}:${result.stdout.toString()}`);
} else {
  console.log('ids=skip');
}
