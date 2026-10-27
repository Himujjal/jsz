// Descriptor-based fs surface: mkdtemp, open/read/write/fstat/fsync/close,
// wx exclusivity, and the fs.promises FileHandle view.
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import { basename, isAbsolute } from 'node:path';

const work = 'tests/fixtures/.fs-fd-work';
const file = work + '/fd.bin';
await fsp.rm(work, { recursive: true, force: true });
await fsp.mkdir(work, { recursive: true });

// mkdtemp: absolute, existing directory, prefix kept, distinct names.
const tempA = await fsp.mkdtemp('jsz-fs-');
const tempB = await fsp.mkdtemp('jsz-fs-');
const tempStat = await fsp.stat(tempA);
console.log(
  'mkdtemp=' +
    isAbsolute(tempA) + ':' +
    tempStat.isDirectory() + ':' +
    basename(tempA).startsWith('jsz-fs-') + ':' +
    (tempA !== tempB) + ':' +
    basename(tempB).startsWith('jsz-fs-'),
);
await fsp.rmdir(tempA);
await fsp.rmdir(tempB);
console.log('mkdtemp-cleaned=' + (await fsp.access(tempA).then(() => false, () => true)));

// Callback mkdtemp uses the same implementation.
const tempCb = await new Promise((resolve, reject) => {
  fs.mkdtemp('jsz-cb-', (error, path) => (error ? reject(error) : resolve(path)));
});
console.log('mkdtemp-callback=' + basename(tempCb).startsWith('jsz-cb-'));
await fsp.rmdir(tempCb);

// Invalid prefixes are rejected before reaching the syscall.
console.log('mkdtemp-empty=' + (await fsp.mkdtemp('').then(() => 'ok', (error) => error.code)));
console.log('mkdtemp-sep=' + (await fsp.mkdtemp('/tmp/nope-').then(() => 'ok', (error) => error.code)));

const fd = await new Promise((resolve, reject) => {
  fs.open(file, 'w+', (error, value) => (error ? reject(error) : resolve(value)));
});
console.log('open=' + typeof fd + ':' + (fd > 2));

await new Promise((resolve, reject) => {
  fs.write(fd, Buffer.from('hello world'), 0, 11, 0, (error) => (error ? reject(error) : resolve()));
});
await new Promise((resolve, reject) => fs.fsync(fd, (error) => (error ? reject(error) : resolve())));
const fdStat = await new Promise((resolve, reject) => {
  fs.fstat(fd, (error, stat) => (error ? reject(error) : resolve(stat)));
});
console.log('fstat=' + fdStat.size + ':' + fdStat.isFile());

const target = Buffer.alloc(5);
const read = await new Promise((resolve, reject) => {
  fs.read(fd, target, 1, 3, 6, (error, count, buffer) =>
    error ? reject(error) : resolve({ count, buffer }),
  );
});
console.log('read=' + read.count + ':' + target.toString('utf8', 1, 1 + read.count) + ':' + (read.buffer === target));

// String writes take the string form and report the same buffer back.
const stringWrite = await new Promise((resolve, reject) => {
  fs.write(fd, 'XY', 0, 'utf8', (error, count, value) =>
    error ? reject(error) : resolve({ count, value }),
  );
});
console.log('write-string=' + stringWrite.count + ':' + stringWrite.value);

await new Promise((resolve, reject) => fs.close(fd, (error) => (error ? reject(error) : resolve())));
const afterClose = await new Promise((resolve) => {
  fs.read(fd, target, 0, 1, 0, (error) => resolve(error && error.code + ':' + error.syscall));
});
const afterCloseFstat = await new Promise((resolve) => {
  fs.fstat(fd, (error) => resolve(error && error.code + ':' + error.syscall));
});
const afterCloseFsync = await new Promise((resolve) => {
  fs.fsync(fd, (error) => resolve(error && error.code + ':' + error.syscall));
});
console.log('closed=' + afterClose);
console.log('closed-fstat=' + afterCloseFstat);
console.log('closed-fsync=' + afterCloseFsync);

// wx is exclusive; the second open keeps the first file.
const exclusive = work + '/exclusive.txt';
const exclusiveFd = await new Promise((resolve, reject) => {
  fs.open(exclusive, 'wx', (error, value) => (error ? reject(error) : resolve(value)));
});
console.log('wx=' + (exclusiveFd > 2));
console.log('wx-twice=' + (await new Promise((resolve) => {
  fs.open(exclusive, 'wx', (error) => resolve(error && error.code + ':' + error.syscall + ':' + (error.path !== undefined)));
})));
await new Promise((resolve, reject) => fs.close(exclusiveFd, (error) => (error ? reject(error) : resolve())));

console.log('open-enoent=' + (await new Promise((resolve) => {
  fs.open(work + '/absent.txt', 'r', (error) => resolve(error && error.code + ':' + error.syscall));
})));
// Node validates flags synchronously in the callback API.
let badFlag = 'ok';
try {
  fs.open(file, 'nope', () => {});
} catch (error) {
  badFlag = error.code;
}
console.log('open-bad-flag=' + badFlag);
console.log('open-bad-flag-async=' + (await fsp.open(file, 'nope').then(() => 'ok', (error) => error.code)));

// fs.promises.open returns a FileHandle backed by the same descriptor pool.
const handle = await fsp.open(file, 'w+');
await handle.writeFile('abcdef');
const handleStat = await handle.stat();
const handleContents = await handle.readFile('utf8');
const handleBuffer = Buffer.alloc(2);
const handleRead = await handle.read(handleBuffer, 0, 2, 1);
console.log(
  'filehandle=' +
    typeof handle.fd + ':' +
    handleStat.size + ':' +
    handleContents + ':' +
    handleRead.bytesRead + ':' +
    handleBuffer.toString('utf8'),
);
await handle.truncate(3);
await handle.write('Z', 2, 'utf8');
console.log('filehandle-edit=' + (await handle.readFile('utf8')));
await handle.sync();
await handle.close();
console.log('filehandle-close-twice=' + ((await handle.close()) === undefined));
console.log('filehandle-closed=' + (await handle.read(handleBuffer, 0, 1, 0).then(() => 'ok', (error) => error.code)));
console.log('filehandle-closed-truncate=' + (await handle.truncate(1).then(() => 'ok', (error) => error.code)));
console.log('filehandle-closed-stat=' + (await handle.stat().then(() => 'ok', (error) => error.code)));

// Append handles ignore positions and always write at the end.
const appender = await fsp.open(file, 'a');
await appender.writeFile('+w');
await appender.appendFile('+a');
await appender.close();
console.log('append=' + (await fsp.readFile(file, 'utf8')));

// A one mebibyte round trip through the descriptor API.
const big = Buffer.alloc(1024 * 1024);
for (let i = 0; i < big.length; i += 1) big[i] = i & 0xff;
const bigHandle = await fsp.open(work + '/big.bin', 'w+');
const bigWrite = await bigHandle.write(big, 0, big.length, 0);
const bigBack = Buffer.alloc(big.length);
const bigRead = await bigHandle.read(bigBack, 0, bigBack.length, 0);
await bigHandle.close();
console.log(
  'big=' +
    (bigWrite.bytesWritten === big.length && bigRead.bytesRead === big.length && Buffer.compare(big, bigBack) === 0) + ':' +
    bigWrite.bytesWritten,
);

// The promise API deliberately mirrors Node: no raw-fd read/write/close.
console.log(
  'promise-fd-api=' +
    [typeof fsp.read, typeof fsp.write, typeof fsp.close, typeof fsp.fsync, typeof fsp.fstat].join(','),
);

await fsp.rm(work, { recursive: true, force: true });
console.log('cleanup=' + (await fsp.access(work).then(() => false, () => true)));
