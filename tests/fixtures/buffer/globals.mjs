// Phase 1: Buffer is a global and identical to the node:buffer export.
import buffer, { Buffer as named } from 'node:buffer';
import fs from 'node:fs';

console.log(`global=${globalThis.Buffer === named}`);
console.log(`default=${buffer.Buffer === named}`);
console.log(`buffer=${named.from('abc').toString()}`);

async function main() {
  const work = 'tests/fixtures/.buffer-work';
  await fs.promises.rm(work, { recursive: true, force: true });
  await fs.promises.mkdir(work, { recursive: true });
  const file = `${work}/a.bin`;
  await fs.promises.writeFile(file, 'hello');

  const raw = await fs.promises.readFile(file);
  console.log(`fs-buffer=${raw instanceof Buffer}:${raw instanceof Uint8Array}:${raw.toString()}`);

  const text = await fs.promises.readFile(file, 'utf8');
  console.log(`fs-text=${typeof text}:${text}`);

  const hex = await fs.promises.readFile(file, 'hex');
  console.log(`fs-hex=${hex}`);

  await fs.promises.rm(work, { recursive: true, force: true });
}

await main();
