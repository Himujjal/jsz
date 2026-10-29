// Derived from test/parallel/test-process-signal.js (nodejs/node).
// With no SIGTERM listener the runtime must exit with 143 (128 + 15). The
// guard keeps a broken watcher from hanging the test forever.
import process from 'node:process';

console.log('ready');
setInterval(() => {}, 1000);
setTimeout(() => process.exit(99), 3000);
