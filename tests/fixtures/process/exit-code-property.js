// Derived from test/parallel/test-process-exit-code.js (nodejs/node).
// A writable process.exitCode drives the normal-exhaustion exit path.
import process from 'node:process';

console.log(`before=${process.exitCode}`);
process.exitCode = 4;
console.log(`after=${process.exitCode}`);
