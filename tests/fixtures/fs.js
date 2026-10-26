import fs from 'node:fs';
import fsBare from 'fs';
import fsp, { Stats, Dirent } from 'node:fs/promises';

const work = 'tests/fixtures/.fs-work';
const file = work + '/a.txt';

await fsp.rm(work, { recursive: true, force: true });
await fsp.mkdir(work, { recursive: true });
await fsp.writeFile(file, 'hello');
console.log('write=' + await fsp.readFile(file, 'utf8'));
await fsp.appendFile(file, ' world');
console.log('append=' + await fsp.readFile(file, 'utf8'));

const stat = await fsp.stat(file);
console.log('stat=' + stat.isFile() + ':' + stat.size + ':' + (stat instanceof Stats));

await fsp.mkdir(work + '/sub');
const names = await fsp.readdir(work);
console.log('readdir=' + names.join(','));
const entries = await fsp.readdir(work, { withFileTypes: true });
console.log('dirent=' + entries.map((entry) => entry.name + ':' + entry.isDirectory()).join(',') + ':' + (entries[0] instanceof Dirent));

await fsp.copyFile(file, work + '/b.txt');
await fsp.rename(work + '/b.txt', work + '/c.txt');
console.log('copy=' + await fsp.readFile(work + '/c.txt', 'utf8'));
console.log('realpath=' + (await fsp.realpath(file)).endsWith('/a.txt'));

await fsp.symlink('a.txt', work + '/link.txt');
console.log('symlink=' + (await fsp.readlink(work + '/link.txt')) + ':' + (await fsp.lstat(work + '/link.txt')).isSymbolicLink() + ':' + (await fsp.stat(work + '/link.txt')).isFile());

await fsp.cp(work + '/c.txt', work + '/d.txt');
console.log('cp=' + await fsp.readFile(work + '/d.txt', 'utf8'));
await fsp.truncate(work + '/d.txt', 5);
console.log('truncate=' + await fsp.readFile(work + '/d.txt', 'utf8'));
await fsp.unlink(work + '/d.txt');
console.log('unlink=' + await fsp.access(work + '/d.txt').then(() => false, () => true));

try {
  await fsp.mkdir(work);
} catch (error) {
  console.log('eexist=' + error.code + ':' + error.syscall + ':' + (error.path !== undefined));
}

// The callback API must never run synchronously.
let returned = false;
const cbValue = await new Promise((resolve) => {
  fs.readFile(file, 'utf8', (error, data) => {
    console.log('callback-before-return=' + !returned);
    resolve(error ? 'error' : data);
  });
  returned = true;
});
console.log('callback=' + cbValue);
console.log('parity=' + (cbValue === await fsp.readFile(file, 'utf8')));
console.log('callback-error=' + await new Promise((resolve) => {
  fs.readFile(work + '/absent.txt', (error) => resolve(error && error.code));
}));

const bytes = await fsp.readFile(work + '/c.txt');
console.log('bytes=' + (bytes instanceof Uint8Array) + ':' + bytes.length);

try {
  await fsp.readFile(work + '/missing.txt');
} catch (error) {
  console.log('enoent=' + error.code + ':' + error.syscall + ':' + (error.path !== undefined) + ':' + (error instanceof Error));
}

try {
  fs.readFileSync(file);
} catch (error) {
  console.log('sync=' + error.code);
}
console.log('existsSync=' + typeof fs.existsSync);
console.log('promises-same=' + (fsp.readFile === fs.promises.readFile));
console.log('alias=' + (fsBare === fs));

await fsp.rm(work, { recursive: true, force: true });
console.log('cleanup=' + await fsp.access(work).then(() => false, () => true));
