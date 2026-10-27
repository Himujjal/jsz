// Derived from test/parallel/test-promise-unhandled-warn.js (nodejs/node).
// Reporting happens at shutdown: the warning names the reason and the exit
// code becomes 1 instead of 0.
import process from 'node:process';

Promise.reject(new Error('boom'));
setTimeout(() => console.log('alive'), 0);
process.on('exit', (code) => console.log(`exit ${code}`));
