// Derived from test/parallel/test-process-exit-code.js (nodejs/node).
// The harness asserts exit code 3 and that the pending timer never fires.
import process from 'node:process';

console.log('before');
setTimeout(() => console.log('late'), 0);
process.exit(3);
