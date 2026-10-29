// Phase 6 fs hardening: recursive readdir, numeric flags, and two-path errors.
import fs from 'node:fs';
import fsp from 'node:fs/promises';

const work = 'tests/fixtures/.fs-hardening-work';
const o = fs.constants;

await fsp.rm(work, { recursive: true, force: true });
await fsp.mkdir(work + '/sub/deep', { recursive: true });
await fsp.writeFile(work + '/a.txt', 'a');
await fsp.writeFile(work + '/sub/b.txt', 'b');
await fsp.writeFile(work + '/sub/deep/c.txt', 'c');

// Recursive readdir returns paths relative to the root, depth-first.
const recursive = await fsp.readdir(work, { recursive: true });
console.log('recursive=' + recursive.join(','));
console.log('recursive-root=' + recursive.includes(work));

const typed = await fsp.readdir(work, { recursive: true, withFileTypes: true });
console.log('typed=' + typed.map((entry) => entry.name + '@' + entry.parentPath).join(','));
console.log('typed-basename=' + typed.every((entry) => !entry.name.includes('/')));
console.log(
  'typed-path-alias=' +
    (typed.every((entry) => entry.path === entry.parentPath)) + ':' +
    (Object.keys(typed[0]).includes('path')),
);

const callbackRecursive = await new Promise((resolve, reject) => {
  fs.readdir(work, { recursive: true }, (error, names) => (error ? reject(error) : resolve(names)));
});
console.log('callback-recursive=' + (callbackRecursive.join(',') === recursive.join(',')));

const flat = await fsp.readdir(work, { withFileTypes: true });
console.log('flat-parent=' + (flat[0].parentPath === work) + ':' + (flat[0].path === work));

// Numeric flags translate to the driver's string flags.
const target = work + '/flags.txt';
const WRITE = o.O_WRONLY | o.O_CREAT | o.O_TRUNC;
const APPEND = o.O_WRONLY | o.O_CREAT | o.O_APPEND;

await fsp.writeFile(target, 'one', { flag: WRITE });
await fsp.appendFile(target, 'two', { flag: APPEND });
console.log('numeric-write=' + await fsp.readFile(target, 'utf8'));

await fsp.writeFile(target, 'reset', { flag: WRITE });
console.log('numeric-truncate=' + await fsp.readFile(target, 'utf8'));

let exclusive = 'ok';
try {
  await fsp.writeFile(target, 'nope', { flag: WRITE | o.O_EXCL });
} catch (error) {
  exclusive = error.code;
}
console.log('numeric-exclusive=' + exclusive + ':' + await fsp.readFile(target, 'utf8'));

const handle = await fsp.open(work + '/handle.txt', o.O_RDWR | o.O_CREAT | o.O_TRUNC);
await handle.writeFile('num');
await handle.close();
console.log('numeric-open=' + await fsp.readFile(work + '/handle.txt', 'utf8'));

const cbFd = await new Promise((resolve, reject) => {
  fs.open(target, APPEND, (error, fd) => (error ? reject(error) : resolve(fd)));
});
await new Promise((resolve, reject) => {
  fs.write(cbFd, 'cb', 0, 'utf8', (error) => (error ? reject(error) : resolve()));
});
await new Promise((resolve, reject) => fs.close(cbFd, (error) => (error ? reject(error) : resolve())));
console.log('numeric-callback=' + await fsp.readFile(target, 'utf8'));

// Masks the translator cannot honor are rejected, never rewritten to 'w'.
const invalid = [
  o.O_RDONLY | o.O_TRUNC,
  o.O_WRONLY,
  o.O_WRONLY | o.O_RDWR,
  o.O_WRONLY | o.O_CREAT | o.O_EXCL,
  1 << 20,
];
const invalidCodes = [];
for (const mask of invalid) {
  invalidCodes.push(await fsp.open(target, mask).then(() => 'ok', (error) => error.code));
}
console.log('numeric-invalid=' + invalidCodes.join(','));
console.log(
  'numeric-invalid-write=' +
    (await fsp.writeFile(target, 'nope', { flag: 3 }).then(() => 'ok', (error) => error.code)) + ':' +
    await fsp.readFile(target, 'utf8'),
);

let syncInvalid = 'ok';
try {
  fs.open(target, o.O_RDONLY | o.O_TRUNC, () => {});
} catch (error) {
  syncInvalid = error.code;
}
console.log('numeric-invalid-sync=' + syncInvalid);

// Append sequences through both the flag default and numeric masks.
const seq = work + '/seq.txt';
await fsp.writeFile(seq, 'base');
for (const part of ['1', '2', '3']) await fsp.appendFile(seq, part);
console.log('append-seq=' + await fsp.readFile(seq, 'utf8'));
for (const part of ['4', '5']) await fsp.appendFile(seq, part, { flag: APPEND });
console.log('append-numeric=' + await fsp.readFile(seq, 'utf8'));

// Two-path operations report the source as `path` and the target as `dest`.
async function shape(fn) {
  try {
    await fn();
    return 'ok';
  } catch (error) {
    return [error.code, error.syscall, error.path, error.dest].join('|');
  }
}
console.log('rename-dest=' + await shape(() => fsp.rename(work + '/absent.txt', work + '/moved.txt')));
console.log('copy-dest=' + await shape(() => fsp.copyFile(work + '/absent.txt', work + '/copy.txt')));
console.log('link-dest=' + await shape(() => fsp.link(work + '/absent.txt', work + '/hard.txt')));
console.log('cp-dest=' + await shape(() => fsp.cp(work + '/sub', work + '/subcopy')));

await fsp.symlink('a.txt', work + '/sym.txt');
console.log('symlink-dest=' + await shape(() => fsp.symlink('a.txt', work + '/sym.txt')));

// Native data that `std.Io.File.Stat` exposes is passed through.
const stat = await fsp.stat(work + '/a.txt');
console.log('stat-block=' + (stat.blksize > 0) + ':' + (stat.nlink >= 1) + ':' + (stat.ino > 0));

await fsp.rm(work, { recursive: true, force: true });
console.log('cleanup=' + await fsp.access(work).then(() => false, () => true));
