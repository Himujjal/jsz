// Phase 1: completions arrive through the job queue while timers keep firing.
// The reads are big enough that the loop must service timer deadlines in the
// middle of the batch; a timing-free assertion would not survive a fast run.
import fs from 'node:fs';

const work = 'tests/fixtures/.async-work';
const source = `${work}/big.bin`;
const size = 512 * 1024;

await fs.promises.rm(work, { recursive: true, force: true });
await fs.promises.mkdir(work, { recursive: true });
await fs.promises.writeFile(source, Buffer.alloc(size, 0x61));

const probe = await fs.promises.readFile(source);
console.log(`probe=${probe.length === size}:${Buffer.isBuffer(probe)}`);

let ticks = 0;
const interval = setInterval(() => {
  ticks += 1;
}, 1);

const reads = [];
for (let index = 0; index < 100; index += 1) {
  reads.push(fs.promises.readFile(source));
}

const results = await Promise.all(reads);
clearInterval(interval);

console.log(`reads=${results.length}`);
console.log(`complete=${results.every((buffer) => buffer.length === size)}`);
console.log(`ticks-during=${ticks > 0}`);

await fs.promises.rm(work, { recursive: true, force: true });
console.log('cleanup=true');
