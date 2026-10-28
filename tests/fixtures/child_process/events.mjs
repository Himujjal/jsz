// Ported from Node's test suite:
//   test-child-process-spawn-event.js
//   test-child-process-spawn-error.js
//   test-child-process-spawn-shell.js
//   test-child-process-spawnsync-kill-signal.js
// Deterministic ESM adaptation; absolute tools so PATH cannot change results.
import { spawn, spawnSync } from 'node:child_process';

function waitClose(child) {
  return new Promise((resolve) => {
    child.on('close', (code, signal) => resolve({ code, signal }));
  });
}

{
  const child = spawn('/bin/sh', ['-c', 'printf out']);
  const events = [];
  child.on('spawn', () => events.push('spawn'));
  child.stdout.on('data', () => events.push('data'));
  child.on('exit', () => events.push('exit'));
  child.on('close', () => events.push('close'));
  await waitClose(child);
  console.log(`order=${events.join('<')}`);
}

{
  const child = spawn('jsz-no-such-command-xyz');
  const events = [];
  let code = null;
  child.on('error', (error) => {
    events.push('error');
    code = error.code;
  });
  child.on('close', () => events.push('close'));
  await new Promise((resolve) => child.on('close', resolve));
  console.log(`error-close=${events.join('<')}:${code}`);
}

{
  const child = spawn('/bin/sh', ['-c', 'kill -TERM $$']);
  await waitClose(child);
  console.log(`signal=SIGTERM:${child.signalCode}`);
}

{
  const child = spawn('/bin/sleep', ['5']);
  child.kill('SIGKILL');
  await waitClose(child);
  console.log(`sigkill=${child.signalCode}`);
}

{
  const child = spawn('echo hi', { shell: true });
  let stdout = '';
  child.stdout.on('data', (chunk) => {
    stdout += chunk.toString();
  });
  await waitClose(child);
  console.log(`shell=${stdout.trim()}`);
}

{
  const base = process.cwd().split('/').filter(Boolean).pop();
  const pwd = spawnSync('/bin/pwd', [], { cwd: process.cwd() });
  const cwdMatches = pwd.stdout.toString().trim().endsWith(base);

  const child = spawn('/bin/sh', ['-c', 'printf %s "$JSZ_ASYNC"'], {
    cwd: process.cwd(),
    env: { ...process.env, JSZ_ASYNC: 'yes' },
  });
  let value = '';
  child.stdout.on('data', (chunk) => {
    value += chunk.toString();
  });
  await waitClose(child);
  console.log(`cwd-env=${cwdMatches}:${value}`);
}

{
  const result = spawnSync('/bin/sh', ['-c', 'kill -TERM $$']);
  console.log(`sync-signal=${result.status}:${result.signal}`);
}
