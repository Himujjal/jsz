// Deterministic coverage of the synchronous child_process surface. Uses only
// absolute tools so the environment and PATH cannot change the result.
import { spawnSync, execSync, execFileSync } from 'node:child_process';

const basic = spawnSync('/bin/sh', ['-c', 'printf hi']);
console.log(`basic=${basic.status}:${basic.stdout.toString()}:${basic.signal}:${basic.error}`);

const failing = spawnSync('/bin/sh', ['-c', 'exit 3']);
console.log(`exit=${failing.status}:${failing.signal}:${failing.error}`);

const missing = spawnSync('/bin/definitely-not-a-command');
console.log(`missing=${missing.error.code}:${missing.status}:${missing.stdout}`);

const cat = spawnSync('/bin/cat', [], { input: 'abc' });
console.log(`input=${cat.status}:${cat.stdout.toString()}`);

const env = spawnSync('/bin/sh', ['-c', 'printf %s "$JSZ_TEST"'], { env: { JSZ_TEST: 'yes' } });
console.log(`env=${env.stdout.toString()}`);

const base = process.cwd().split('/').filter(Boolean).pop();
const dir = spawnSync('/bin/pwd', [], { cwd: process.cwd() });
console.log(`cwd=${dir.status}:${dir.stdout.toString().trim().endsWith(base)}`);

console.log(`exec=${execSync('printf hi', { encoding: 'utf8' })}`);
console.log(`exec-file=${execFileSync('/bin/sh', ['-c', 'printf hi'], { encoding: 'utf8' })}`);

let execError = null;
try {
  execSync('exit 3');
} catch (error) {
  execError = error;
}
console.log(
  `exec-error=${execError.status}:${Buffer.isBuffer(execError.stdout)}:${Buffer.isBuffer(execError.stderr)}:${execError.output.length}`,
);

const small = spawnSync('/bin/sh', ['-c', 'printf 1234567890'], { maxBuffer: 4 });
console.log(`maxbuffer=${small.error.code}`);

let maxError = null;
try {
  execSync('printf 1234567890', { maxBuffer: 4 });
} catch (error) {
  maxError = error;
}
console.log(`maxbuffer-exec=${maxError.code}`);

const ignored = spawnSync('/bin/sh', ['-c', 'printf hi'], { stdio: 'ignore' });
console.log(`ignore=${ignored.status}:${ignored.stdout}`);

const shell = spawnSync('printf hi', { shell: true });
console.log(`shell=${shell.status}:${shell.stdout.toString()}`);

process.env.JSZ_INHERIT_TEST = 'inherited';
const inherited = spawnSync('/bin/sh', ['-c', 'printf %s "$JSZ_INHERIT_TEST"']);
console.log(`inherit=${inherited.stdout.toString()}`);
