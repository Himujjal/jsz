// Derived from test/parallel/test-process-stdout-write.js (nodejs/node).
// stdout and stderr share the captured buffer console uses.
import process from 'node:process';

const outResult = process.stdout.write('out-1\n');
const errResult = process.stderr.write('err-1\n');
process.stdout.write(Buffer.from('out-2\n'));
process.stdout.write('cb\n', () => console.log('callback'));
process.stdout.write('6869', 'hex');
console.log('');

console.log(`return=${outResult}:${errResult}`);
console.log(`tty=${process.stdout.isTTY}`);
console.log(`size=${typeof process.stdout.columns}:${typeof process.stdout.rows}`);

let invalid = false;
try {
  process.stdout.write('x', 'not-an-encoding');
} catch (error) {
  invalid = error.code === 'ERR_UNKNOWN_ENCODING';
}
console.log(`invalid=${invalid}`);
