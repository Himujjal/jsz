// Derived from test/parallel/test-process-signal.js (nodejs/node).
// A SIGINT listener keeps the loop alive; the guard only fires when the
// signal never arrives so the Zig test cannot hang.
import process from 'node:process';

console.log('ready');
const interval = setInterval(() => {}, 1000);
const guard = setTimeout(() => process.exit(99), 3000);

process.on('SIGINT', () => {
  clearInterval(interval);
  clearTimeout(guard);
  console.log('sigint');
  setTimeout(() => console.log('after'), 0);
});
