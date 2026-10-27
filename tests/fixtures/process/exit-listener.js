// Derived from test/parallel/test-process-exit-handler.js (nodejs/node).
// The exit listener runs exactly once, before stdout is flushed.
import process from 'node:process';

process.on('exit', (code) => console.log(`exit ${code}`));
