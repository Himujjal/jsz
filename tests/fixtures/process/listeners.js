// Derived from test/parallel/test-process-exit-handler.js (nodejs/node).
// Exercises on/once/off/removeListener/removeAllListeners bookkeeping.
import process from 'node:process';

const calls = [];
const first = (code) => calls.push(`first:${code}`);
const second = (code) => calls.push(`second:${code}`);
const third = (code) => calls.push(`third:${code}`);

process.on('exit', first);
process.once('exit', second);
process.on('exit', third);
process.off('exit', third);
process.removeListener('exit', first);
console.log(`count-1=${process.listenerCount('exit')}`);

process.on('exit', first);
process.on('exit', third);
console.log(`count-2=${process.listenerCount('exit')}`);
process.removeAllListeners('exit');
console.log(`count-3=${process.listenerCount('exit')}`);

process.once('exit', (code) => calls.push(`once:${code}`));
process.once('exit', (code) => calls.push(`once:${code + 1}`));
process.on('exit', (code) => {
  console.log(calls.join(','));
  console.log(`count-exit=${process.listenerCount('exit')}`);
  console.log(`code=${code}`);
});
