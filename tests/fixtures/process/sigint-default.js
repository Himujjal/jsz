// Derived from test/parallel/test-process-signal.js (nodejs/node).
// With no SIGINT listener the runtime must exit with 130. The guard keeps a
// broken watcher from hanging the Zig test forever.
import process from 'node:process';

console.log('ready');
setInterval(() => {}, 1000);
setTimeout(() => process.exit(99), 3000);
