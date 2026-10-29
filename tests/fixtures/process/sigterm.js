// Derived from test/parallel/test-process-signal.js (nodejs/node).
// A SIGTERM listener keeps the loop alive; the guard only fires when the
// signal never arrives so the Zig test cannot hang.
import process from 'node:process';

console.log('ready');
const interval = setInterval(() => {}, 1000);
const guard = setTimeout(() => process.exit(99), 3000);

process.on('SIGTERM', (signal) => {
  clearInterval(interval);
  clearTimeout(guard);
  console.log(signal);
  setTimeout(() => console.log('after'), 0);
});
