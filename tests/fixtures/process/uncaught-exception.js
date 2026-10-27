// Derived from test/parallel/test-process-exception-capture.js (nodejs/node).
// An uncaughtException listener turns a throwing timer into a warning and the
// loop keeps running.
import process from 'node:process';

const seen = [];
process.on('uncaughtException', (error) => {
  seen.push(error.message);
  console.log(`caught ${error.message}`);
});

setTimeout(() => {
  throw new Error('boom');
}, 0);
setTimeout(() => {
  console.log(`alive=${seen.length}`);
}, 5);
