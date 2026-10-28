// Deterministic coverage of the asynchronous child_process surface. Uses only
// absolute tools so the environment and PATH cannot change the result.
import { spawn, exec, execFile } from 'node:child_process';

function waitClose(child) {
  return new Promise((resolve) => {
    child.on('close', (code, signal) => resolve({ code, signal }));
  });
}

{
  const child = spawn('/bin/sh', ['-c', 'printf out; printf err >&2']);
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => {
    stdout += chunk.toString();
  });
  child.stderr.on('data', (chunk) => {
    stderr += chunk.toString();
  });
  const result = await waitClose(child);
  console.log(`spawn=${result.code}:${result.signal}:${stdout}:${stderr}:${typeof child.pid}`);
}

{
  const stdout = await new Promise((resolve, reject) => {
    exec('printf hi', (error, output) => {
      if (error) reject(error);
      else resolve(output);
    });
  });
  console.log(`exec=${stdout}`);
}

{
  const stdout = await new Promise((resolve, reject) => {
    execFile('/bin/sh', ['-c', 'printf file'], (error, output) => {
      if (error) reject(error);
      else resolve(output);
    });
  });
  console.log(`execFile=${stdout}`);
}

{
  const child = spawn('/bin/cat', []);
  let stdout = '';
  child.stdout.on('data', (chunk) => {
    stdout += chunk.toString();
  });
  const closed = waitClose(child);
  child.stdin.write('abc');
  child.stdin.end();
  const result = await closed;
  console.log(`stdin=${result.code}:${stdout}`);
}

{
  const child = spawn('/bin/sleep', ['30']);
  const closed = waitClose(child);
  child.kill('SIGTERM');
  const result = await closed;
  console.log(`kill=${result.code}:${result.signal}`);
}

{
  const code = await new Promise((resolve) => {
    const child = spawn('jsz-no-such-command-xyz');
    child.on('error', (error) => resolve(error.code));
  });
  console.log(`missing=${code}`);
}

{
  const summary = await new Promise((resolve) => {
    exec('exit 3', (error) => resolve(`${error.code}:${error.status}`));
  });
  console.log(`exit=${summary}`);
}

{
  process.env.JSZ_INHERIT_TEST = 'inherited';
  const child = spawn('/bin/sh', ['-c', 'printf %s "$JSZ_INHERIT_TEST"']);
  let stdout = '';
  child.stdout.on('data', (chunk) => {
    stdout += chunk.toString();
  });
  await waitClose(child);
  console.log(`inherit=${stdout}`);
}

{
  const code = await new Promise((resolve) => {
    exec('printf 1234567890', { maxBuffer: 4 }, (error) => resolve(error.code));
  });
  console.log(`maxbuffer=${code}`);
}

{
  let sawData = false;
  const child = spawn('/bin/sh', ['-c', 'printf hi'], { stdio: 'ignore' });
  child.stdout.on('data', () => {
    sawData = true;
  });
  const result = await waitClose(child);
  console.log(`ignore=${result.code}:${sawData ? 'data' : 'none'}`);
}
