// Phase 1 exit criteria: the loop returns once the last awaited job settles,
// with no timers and no references left.
import fs from 'node:fs';

const first = await fs.promises.readFile('tests/fixtures/async/timers_during_io.mjs', 'utf8');
const second = await fs.promises.readFile('tests/fixtures/async/exit_with_pending_job.mjs', 'utf8');

console.log(`first=${first.length > 0}`);
console.log(`second=${second.length > 0}`);
console.log('done');
