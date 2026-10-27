// Derived from test/parallel/test-process-exit-handler.js (nodejs/node).
// A top-level throw still reaches exit listeners, with code 1.
import process from 'node:process';

process.on('exit', (code) => console.log(`exit ${code}`));
throw new Error('boom');
