// Derived from test/parallel/test-process-exception-capture.js (nodejs/node).
// uncaughtException also covers the script preamble; handled errors exit 0.
import process from 'node:process';

process.on('uncaughtException', (error) => console.log(`caught ${error.message}`));
throw new Error('boom');
