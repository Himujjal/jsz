// A ready fs completion must not strand its promise continuation when the
// loop runs out of other work.
import fs from 'node:fs';
import process from 'node:process';

globalThis.__result = '';
fs.promises.readFile(`${process.cwd()}/build.zig.zon`, 'utf8').then(() => {
  globalThis.__result = 'done';
});
