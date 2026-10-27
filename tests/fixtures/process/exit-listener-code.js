// Derived from test/parallel/test-process-exit-handler.js (nodejs/node).
// process.exit(3) hands 3 to the exit listener and keeps that exit code.
import process from 'node:process';

process.on('exit', (code) => console.log(`exit ${code}`));
process.exit(3);
