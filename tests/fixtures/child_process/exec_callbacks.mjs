// Ported from Node's test suite:
//   test-child-process-exec-error.js
//   test-child-process-exec-encoding.js
//   test-child-process-execfile.js
//   test-child-process-exec-cwd.js
//   test-child-process-exec-env.js
// Deterministic ESM adaptation. Node's `exec` runs through `/bin/sh`, so a
// missing command reports the shell's 127; the shell-less `execFile` reports
// ENOENT with empty stdout/stderr.
import { exec, execFile } from 'node:child_process';

function execResult(run) {
  return new Promise((resolve) => {
    run((error, stdout, stderr) => resolve({ error, stdout, stderr }));
  });
}

{
  const { error } = await execResult((callback) => execFile('jsz-no-such-command-xyz', callback));
  console.log(
    `missing=${error.code}:${error.killed}:${error.signal}:${error.stdout.length}:${error.stderr.length}`,
  );
}

{
  const { error } = await execResult((callback) => exec('jsz-no-such-command-xyz', callback));
  console.log(`missing-shell=${error.code}`);
}

{
  const { error } = await execResult((callback) =>
    exec('/bin/sh -c "printf out; printf err >&2; exit 3"', callback),
  );
  console.log(
    `exec-error=${error.code}:${error.status}:${error.signal}:${error.stdout}:${error.stderr}:${error.output.length}`,
  );
}

{
  const { stdout } = await execResult((callback) => exec('printf hi', { encoding: 'utf8' }, callback));
  console.log(`encoding=utf8:${stdout}`);
}

{
  const { stdout } = await execResult((callback) =>
    execFile('/bin/sh', ['-c', 'printf hi'], { encoding: 'buffer' }, callback),
  );
  console.log(`buffer=${Buffer.isBuffer(stdout)}:${stdout.length}`);
}

{
  const { error } = await execResult((callback) =>
    execFile('/bin/sh', ['-c', 'exit 4'], callback),
  );
  console.log(`execfile-status=${error.status}`);
}

{
  const { stdout } = await execResult((callback) =>
    exec('pwd', { cwd: '/tmp', encoding: 'utf8' }, callback),
  );
  console.log(`cwd=${stdout.trim().endsWith('tmp')}`);
}

{
  const { stdout } = await execResult((callback) =>
    exec('printf %s "$JSZ_EXEC_ENV"', { env: { JSZ_EXEC_ENV: 'env' }, encoding: 'utf8' }, callback),
  );
  console.log(`env=${stdout}`);
}

{
  const { error } = await execResult((callback) =>
    exec('printf 1234567890', { maxBuffer: 4 }, callback),
  );
  console.log(`maxbuffer=${error.code}`);
}

{
  const { error } = await execResult((callback) =>
    exec('sleep 30', { timeout: 30, killSignal: 'SIGKILL' }, callback),
  );
  console.log(`timeout=${error.killed}:${error.signal}`);
}

{
  const controller = new AbortController();
  setTimeout(() => controller.abort(), 20);
  const { error } = await execResult((callback) =>
    exec('sleep 30', { signal: controller.signal }, callback),
  );
  console.log(`abort=${error.code}:${error.name}:${error.killed}`);
}
