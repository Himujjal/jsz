// Derived from test/parallel/test-process-exit-code.js (nodejs/node).
// Asserts that buffered stream writes are flushed before exit(3).
import process from 'node:process';

process.stdout.write('written\n');
setTimeout(() => process.stdout.write('late\n'), 0);
process.exit(3);
