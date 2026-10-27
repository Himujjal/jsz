// Phase 1 exit criteria: pending I/O must not block process.exit.
// The 50 reads are still queued when exit(7) runs; the runtime may wait for
// them but must not run their promise handlers or hang.
import fs from 'node:fs';
import process from 'node:process';

const source = 'tests/fixtures/async/timers_during_io.mjs';
const reads = [];
for (let index = 0; index < 50; index += 1) {
  reads.push(fs.promises.readFile(source, 'utf8'));
}

reads.forEach((read) => {
  read.then(() => console.log('late'), () => console.log('late-error'));
});

console.log('before');
process.exit(7);
