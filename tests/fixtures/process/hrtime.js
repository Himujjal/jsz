// Derived from test/parallel/test-process-hrtime.js and
// test-process-hrtime-bigint.js (nodejs/node).
import process from 'node:process';

const started = process.hrtime();
console.log(`shape=${Array.isArray(started) && started.length === 2 && started.every(Number.isInteger)}`);
console.log(`nanos=${started[1] >= 0 && started[1] < 1e9}`);

// Busy-wait so the diff is positive without depending on the event loop.
const spin = Date.now();
while (Date.now() - spin < 2) {
  // spin
}

const diff = process.hrtime(started);
console.log(`diff-seconds=${diff[0]}`);
console.log(`diff-positive=${diff[0] > 0 || diff[1] > 0}`);

const later = process.hrtime(started);
console.log(`monotonic=${later[0] > diff[0] || (later[0] === diff[0] && later[1] >= diff[1])}`);

const big = process.hrtime.bigint();
console.log(`bigint=${typeof big === 'bigint' && big > 0n}`);
