// Async-only port of Node.js 22 `node:fs`.
// Every operation runs in a zio I/O task through `node:_fs`; nothing blocks the
// JS task. `*Sync` names exist only to fail loudly.

import * as native from 'node:_fs';
import { Buffer } from 'node:buffer';
import { join } from 'node:path';

export const constants = {
  F_OK: 0,
  R_OK: 4,
  W_OK: 2,
  X_OK: 1,
  COPYFILE_EXCL: 1,
  O_RDONLY: 0,
  O_WRONLY: 1,
  O_RDWR: 2,
  O_CREAT: 64,
  O_EXCL: 128,
  O_TRUNC: 512,
  O_APPEND: 1024,
  // The sync bits are accepted for Node compatibility but the translator opens
  // without O_SYNC, so they never reach a syscall.
  O_DSYNC: 4096,
  O_SYNC: 8192,
  S_IFMT: 0o170000,
  S_IFREG: 0o100000,
  S_IFDIR: 0o040000,
  S_IFLNK: 0o120000,
};

function invalidArg(name, value, reason = 'is invalid') {
  const error = new TypeError(`The "${name}" argument ${reason}: ${String(value)}`);
  error.code = 'ERR_INVALID_ARG_VALUE';
  return error;
}

function invalidArgType(name, expected, value) {
  const error = new TypeError(`The "${name}" argument must be of type ${expected}. Received ${typeof value}`);
  error.code = 'ERR_INVALID_ARG_TYPE';
  return error;
}

function outOfRange(name, value, range) {
  const error = new RangeError(`The value of "${name}" is out of range. It must be ${range}. Received ${value}`);
  error.code = 'ERR_OUT_OF_RANGE';
  return error;
}

function badFd(syscall) {
  const error = new Error(`EBADF: bad file descriptor, ${syscall}`);
  error.code = 'EBADF';
  error.errno = -9;
  error.syscall = syscall;
  return error;
}

function invalidEncoding(encoding) {
  return invalidArg('encoding', encoding, 'is invalid encoding');
}

/// Returns `null` for a Buffer result, `'utf8'` for the native string path, or
/// any other supported Buffer encoding name.
function asTextEncoding(encoding) {
  const normalized = String(encoding).toLowerCase().replace(/-/g, '');
  if (normalized === 'buffer') return null;
  if (normalized === 'utf8') return 'utf8';
  if (!Buffer.isEncoding(normalized)) throw invalidEncoding(encoding);
  return normalized;
}

function readOptions(options) {
  if (options == null) return null;
  if (typeof options === 'string') return asTextEncoding(options);
  if (typeof options !== 'object') throw invalidArg('options', options);

  if (options.encoding == null) return null;
  return asTextEncoding(options.encoding);
}

function writeFlag(options) {
  if (options == null) return null;
  if (typeof options === 'string') return null;
  if (typeof options !== 'object') throw invalidArg('options', options);
  return normalizeFlags(options.flag, 'flag');
}

function mkdirMode(options) {
  if (options == null || typeof options !== 'object') return 0o777;
  return typeof options.mode === 'number' ? options.mode : 0o777;
}

function toBytes(data) {
  if (typeof data === 'string') return data;
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (ArrayBuffer.isView(data)) {
    return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  }
  throw invalidArg('data', data, 'must be a string, Buffer, or Uint8Array');
}

function nodeify(promise, callback) {
  promise.then(
    (value) => callback(null, value),
    (error) => callback(error),
  );
}

function requireCallback(callback) {
  if (typeof callback !== 'function') {
    throw new TypeError('The "cb" argument must be of type function');
  }
}

// Descriptors opened through this module. Tracking lets `close`/`FileHandle`
// release only jsz-owned state; inherited descriptors still close natively.
const openFds = new Set();
const appendFds = new Set();

function requireFd(fd) {
  if (typeof fd !== 'number' || !Number.isInteger(fd) || fd < 0) {
    throw invalidArgType('fd', 'integer', fd);
  }
  return fd;
}

function toView(value, name) {
  if (!ArrayBuffer.isView(value)) {
    throw invalidArgType(name, 'Buffer, TypedArray, or DataView', value);
  }
  return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
}

function checkRange(offset, length, size) {
  if (!Number.isInteger(offset) || offset < 0 || offset > size) {
    throw outOfRange('offset', offset, `>= 0 and <= ${size}`);
  }
  if (!Number.isInteger(length) || length < 0 || offset + length > size) {
    throw outOfRange('length', length, `>= 0 and <= ${size - offset}`);
  }
}

function normalizePosition(position) {
  if (position === undefined || position === null || position === -1) return -1;
  if (!Number.isInteger(position) || position < -1) {
    throw outOfRange('position', position, '>= -1');
  }
  return position;
}

// Mirrors the native flag table so callers get Node's synchronous validation
// instead of an fs error delivered through the callback.
const OPEN_FLAG_NAMES = new Set([
  'r', 'r+', 'rs', 'rs+',
  'w', 'wx', 'xw', 'w+', 'wx+', 'xw+',
  'a', 'ax', 'xa', 'a+', 'ax+', 'xa+', 'as', 'as+',
]);

const WRITE_FLAG_NAMES = new Set([
  'w', 'wx', 'xw', 'w+', 'wx+', 'xw+',
  'a', 'ax', 'xa', 'a+', 'ax+', 'xa+', 'as', 'as+',
]);

const ACCESS_MASK = constants.O_WRONLY | constants.O_RDWR;
const SYNC_BITS = constants.O_SYNC | constants.O_DSYNC;
const FLAG_BITS =
  constants.O_CREAT | constants.O_EXCL | constants.O_TRUNC | constants.O_APPEND | SYNC_BITS;

function unsupportedFlags(name, value, detail) {
  return invalidArg(name, value, `is invalid (${detail})`);
}

/// Accepts Node's string flags or a numeric `fs.constants.O_*` mask and returns
/// a translator-supported string. Masks the driver cannot express are rejected
/// rather than silently rewritten to another mode.
function normalizeFlags(flags, name = 'flags') {
  if (flags === undefined || flags === null) return null;
  if (typeof flags === 'string') {
    if (!OPEN_FLAG_NAMES.has(flags)) throw invalidArg(name, flags, 'is invalid');
    return flags;
  }
  if (typeof flags !== 'number') throw invalidArgType(name, 'string or integer', flags);
  return numericFlags(flags, name);
}

function numericFlags(value, name) {
  if (!Number.isInteger(value) || value < 0) throw invalidArg(name, value, 'is invalid');

  const unknown = value & ~(ACCESS_MASK | FLAG_BITS);
  if (unknown !== 0) {
    throw unsupportedFlags(name, value, `unsupported bits 0x${unknown.toString(16)}`);
  }

  const access = value & ACCESS_MASK;
  if (access === ACCESS_MASK) throw unsupportedFlags(name, value, 'invalid access mode');

  const create = (value & constants.O_CREAT) !== 0;
  const exclusive = (value & constants.O_EXCL) !== 0;
  const truncate = (value & constants.O_TRUNC) !== 0;
  const append = (value & constants.O_APPEND) !== 0;
  const sync = (value & SYNC_BITS) !== 0;

  if (exclusive && !create) throw unsupportedFlags(name, value, 'O_EXCL requires O_CREAT');
  if (truncate && !create) throw unsupportedFlags(name, value, 'O_TRUNC requires O_CREAT');
  if (append && !create) throw unsupportedFlags(name, value, 'O_APPEND requires O_CREAT');

  if (access === constants.O_RDONLY) {
    if (create || append || truncate) {
      throw unsupportedFlags(name, value, 'read-only access cannot create or truncate');
    }
    return sync ? 'rs' : 'r';
  }

  if (!create) {
    if (access === constants.O_WRONLY) {
      throw unsupportedFlags(name, value, 'write-only access requires O_CREAT');
    }
    return sync ? 'rs+' : 'r+';
  }

  if (create && !append && !truncate) {
    throw unsupportedFlags(name, value, 'O_CREAT requires O_TRUNC or O_APPEND');
  }

  if (append) {
    const base = access === constants.O_RDWR ? 'a+' : 'a';
    if (exclusive) return `${base}x`;
    return sync ? `as${base === 'a' ? '' : '+'}` : base;
  }

  if (access === constants.O_RDWR) return exclusive ? 'wx+' : 'w+';
  return exclusive ? 'wx' : 'w';
}

/// Write paths share the flag table: `a*` appends through the native append
/// path, everything else truncates or creates through `writeFile`.
async function writeWithFlag(path, bytes, flag) {
  if (!WRITE_FLAG_NAMES.has(flag)) {
    throw invalidArg('flag', flag, 'is not supported for writing');
  }
  const exclusive = flag.includes('x');
  if (flag[0] === 'a') return native.appendFile(path, bytes, exclusive);
  return native.writeFile(path, bytes, exclusive);
}

function entriesFrom(raw, dir, withFileTypes) {
  if (!withFileTypes) return raw.map((entry) => entry.name);
  return raw.map((entry) => new Dirent(entry.name, entry.kind, dir));
}

/// Depth-first walk matching Node's recursive `readdir`: each directory's
/// sorted entries are emitted before descending, and `rel` is '/'-joined from
/// the root so returned paths stay relative.
async function readdirRecursive(root, rel, out, withFileTypes) {
  const dir = rel === '' ? root : join(root, rel);
  for (const entry of await native.readdir(dir)) {
    const childRel = rel === '' ? entry.name : `${rel}/${entry.name}`;
    out.push(withFileTypes ? new Dirent(entry.name, entry.kind, dir) : childRel);
    if (entry.kind === 'dir') await readdirRecursive(root, childRel, out, withFileTypes);
  }
}

async function openFd(path, flag, mode) {
  const fd = await native.open(path, flag, mode === undefined ? 0o666 : mode);
  openFds.add(fd);
  if (flag.includes('a')) appendFds.add(fd);
  return fd;
}

async function closeFd(fd) {
  requireFd(fd);
  // Never close stdio through the wrapper: a stray fs.close(1) would silently
  // break console output for the rest of the process.
  if (fd <= 2) throw badFd('close');
  openFds.delete(fd);
  appendFds.delete(fd);
  return native.close(fd);
}

async function readInto(fd, buffer, offset, length, position) {
  requireFd(fd);
  const view = toView(buffer, 'buffer');
  if (offset === undefined || offset === null) offset = 0;
  if (length === undefined || length === null) length = view.length - offset;
  checkRange(offset, length, view.length);

  const bytes = await native.read(fd, length, normalizePosition(position));
  view.set(bytes, offset);
  return { bytesRead: bytes.length, buffer };
}

async function writeBytes(fd, bytes, position) {
  requireFd(fd);
  if (bytes.length === 0) return 0;
  return native.write(fd, bytes, normalizePosition(position), appendFds.has(fd));
}

async function writeBuffer(fd, buffer, offset, length, position) {
  const view = toView(buffer, 'buffer');
  if (offset === undefined || offset === null) offset = 0;
  if (length === undefined || length === null) length = view.length - offset;
  checkRange(offset, length, view.length);
  const bytesWritten = await writeBytes(fd, view.subarray(offset, offset + length), position);
  return { bytesWritten, buffer };
}

async function writeString(fd, string, position, encoding) {
  const bytes = Buffer.from(string, encoding === undefined ? 'utf8' : encoding);
  const bytesWritten = await writeBytes(fd, bytes, position);
  return { bytesWritten, string };
}

async function fsyncFd(fd) {
  requireFd(fd);
  return native.fsync(fd);
}

async function fstatFd(fd) {
  requireFd(fd);
  return new Stats(await native.fstat(fd));
}

function writeEncoding(options) {
  if (options == null) return 'utf8';
  if (typeof options === 'string') return options;
  if (typeof options !== 'object') throw invalidArg('options', options);
  return options.encoding === undefined ? 'utf8' : options.encoding;
}

function tempPrefix(prefix) {
  if (typeof prefix !== 'string') throw invalidArgType('prefix', 'string', prefix);
  if (prefix.length === 0) throw invalidArg('prefix', prefix, 'must be a non-empty string');
  if (prefix.includes('/') || prefix.includes('\\')) {
    throw invalidArg('prefix', prefix, 'must not contain path separators');
  }
  return prefix;
}

export class Stats {
  constructor(raw) {
    this.dev = 0;
    this.ino = raw.ino;
    this.mode = raw.mode;
    this.nlink = raw.nlink;
    // std.Io.File.Stat exposes no uid/gid/rdev, so these stay zero.
    this.uid = 0;
    this.gid = 0;
    this.rdev = 0;
    this.size = raw.size;
    this.blksize = raw.blockSize;
    // Node reports allocated 512-byte blocks; only the size is available here.
    this.blocks = Math.ceil(raw.size / 512);
    this.atimeMs = raw.atimeMs;
    this.mtimeMs = raw.mtimeMs;
    this.ctimeMs = raw.ctimeMs;
    this.birthtimeMs = raw.birthtimeMs;
    this.atime = new Date(raw.atimeMs);
    this.mtime = new Date(raw.mtimeMs);
    this.ctime = new Date(raw.ctimeMs);
    this.birthtime = new Date(raw.birthtimeMs);
    Object.defineProperty(this, '_kind', { value: raw.kind });
  }

  isFile() {
    return this._kind === 'file';
  }

  isDirectory() {
    return this._kind === 'dir';
  }

  isSymbolicLink() {
    return this._kind === 'symlink';
  }

  isFIFO() {
    return this._kind === 'fifo';
  }

  isSocket() {
    return this._kind === 'socket';
  }

  isBlockDevice() {
    return this._kind === 'block';
  }

  isCharacterDevice() {
    return this._kind === 'char';
  }
}

export class Dirent {
  constructor(name, kind, parentPath = '') {
    this.name = name;
    this.parentPath = parentPath;
    Object.defineProperty(this, '_kind', { value: kind });
    // Node <= 20 exposed the containing directory as `path`; keep it as a
    // non-enumerable alias so older callers keep working.
    Object.defineProperty(this, 'path', {
      get() {
        return this.parentPath;
      },
      enumerable: false,
      configurable: true,
    });
  }

  isFile() {
    return this._kind === 'file';
  }

  isDirectory() {
    return this._kind === 'dir';
  }

  isSymbolicLink() {
    return this._kind === 'symlink';
  }

  isFIFO() {
    return this._kind === 'fifo';
  }

  isSocket() {
    return this._kind === 'socket';
  }

  isBlockDevice() {
    return this._kind === 'block';
  }

  isCharacterDevice() {
    return this._kind === 'char';
  }
}

class FileHandle {
  constructor(fd, flags) {
    this.fd = fd;
    this._flags = flags;
    this._closed = false;
  }

  async read(buffer, offset, length, position) {
    return readInto(this.fd, buffer, offset, length, position);
  }

  async readFile(options) {
    const encoding = readOptions(options);
    const chunks = [];
    let position = 0;
    for (;;) {
      const bytes = await native.read(this.fd, 64 * 1024, position);
      if (bytes.length === 0) break;
      chunks.push(bytes);
      position += bytes.length;
    }
    const buffer = Buffer.concat(chunks);
    return encoding === null ? buffer : buffer.toString(encoding);
  }

  async write(buffer, offset, length, position) {
    if (typeof buffer === 'string') {
      return writeString(this.fd, buffer, offset, length);
    }
    return writeBuffer(this.fd, buffer, offset, length, position);
  }

  async writeFile(data, options) {
    return this._writeAll(data, options, appendFds.has(this.fd));
  }

  async appendFile(data, options) {
    return this._writeAll(data, options, true);
  }

  async _writeAll(data, options, append) {
    const bytes = typeof data === 'string'
      ? Buffer.from(data, writeEncoding(options))
      : toView(data, 'data');
    let written = 0;
    let position = append ? -1 : 0;
    while (written < bytes.length) {
      const count = await native.write(this.fd, bytes.subarray(written), position, append);
      if (count <= 0) break;
      written += count;
      if (position >= 0) position += count;
    }
  }

  async truncate(len = 0) {
    requireFd(this.fd);
    return native.ftruncate(this.fd, len);
  }

  async stat() {
    return fstatFd(this.fd);
  }

  async sync() {
    return fsyncFd(this.fd);
  }

  async close() {
    if (this._closed) return;
    this._closed = true;
    await closeFd(this.fd);
  }
}

export const promises = {
  async mkdtemp(prefix) {
    return native.mkdtemp(tempPrefix(prefix));
  },

  async open(path, flags, mode) {
    const flag = normalizeFlags(flags) ?? 'r';
    return new FileHandle(await openFd(path, flag, mode), flag);
  },

  async readFile(path, options) {
    const encoding = readOptions(options);
    // `utf8` goes through the native string path; every other encoding is
    // applied to the raw bytes so hex/base64 see the file's real contents.
    if (encoding === 'utf8') return native.readFile(path, true);

    const buffer = Buffer.from(await native.readFile(path, false));
    return encoding === null ? buffer : buffer.toString(encoding);
  },

  async writeFile(path, data, options) {
    const flag = writeFlag(options) ?? 'w';
    return writeWithFlag(path, toBytes(data), flag);
  },

  async appendFile(path, data, options) {
    const flag = writeFlag(options) ?? 'a';
    return writeWithFlag(path, toBytes(data), flag);
  },

  async stat(path) {
    return new Stats(await native.stat(path, true));
  },

  async lstat(path) {
    return new Stats(await native.stat(path, false));
  },

  async readdir(path, options) {
    const recursive = !!(options && typeof options === 'object' && options.recursive);
    const withFileTypes = !!(options && typeof options === 'object' && options.withFileTypes);
    if (!recursive) {
      const raw = await native.readdir(path);
      return entriesFrom(raw, path, withFileTypes);
    }
    const out = [];
    await readdirRecursive(path, '', out, withFileTypes);
    return out;
  },

  async mkdir(path, options) {
    const recursive = !!(options && typeof options === 'object' && options.recursive);
    return native.mkdir(path, recursive, mkdirMode(options));
  },

  async rmdir(path, options) {
    const recursive = !!(options && typeof options === 'object' && options.recursive);
    return native.remove(path, recursive, false, true);
  },

  async rm(path, options) {
    const recursive = !!(options && typeof options === 'object' && options.recursive);
    const force = !!(options && typeof options === 'object' && options.force);
    return native.remove(path, recursive, force, false);
  },

  async unlink(path) {
    return native.remove(path, false, false, false);
  },

  async rename(oldPath, newPath) {
    return native.rename(oldPath, newPath);
  },

  async copyFile(src, dest, mode) {
    return native.copyFile(src, dest, mode === constants.COPYFILE_EXCL);
  },

  async cp(src, dest, options) {
    const recursive = !!(options && typeof options === 'object' && options.recursive);
    const force = !(options && typeof options === 'object' && options.force === false);
    const stat = await promises.lstat(src);

    if (stat.isDirectory()) {
      if (!recursive) {
        const error = new Error(`Cannot copy directory '${src}' without recursive: true`);
        error.code = 'ERR_FS_EISDIR';
        error.syscall = 'cp';
        error.path = src;
        error.dest = dest;
        throw error;
      }
      await promises.mkdir(dest, { recursive: true });
      for (const name of await promises.readdir(src)) {
        await promises.cp(join(src, name), join(dest, name), options);
      }
      return;
    }

    if (!force) {
      const exists = await promises.access(dest).then(() => true, () => false);
      if (exists) return;
    }
    return promises.copyFile(src, dest);
  },

  async access(path, mode = constants.F_OK) {
    return native.access(path, mode);
  },

  async realpath(path) {
    return native.realpath(path);
  },

  async readlink(path) {
    return native.readlink(path);
  },

  async symlink(target, path) {
    return native.symlink(target, path);
  },

  async truncate(path, length = 0) {
    return native.truncate(path, length);
  },

  async chmod(path, mode) {
    return native.chmod(path, mode);
  },

  async chown(path, uid, gid) {
    return native.chown(path, uid, gid);
  },

  async link(existingPath, newPath) {
    return native.link(existingPath, newPath);
  },

  async utimes(path, atime, mtime) {
    return native.utimes(path, toMillis(atime), toMillis(mtime));
  },
};

function toMillis(value) {
  // Node's numeric utimes arguments are seconds; `Date` yields milliseconds.
  if (value instanceof Date) return value.getTime();
  if (typeof value === 'number') return value * 1000;
  throw invalidArg('time', value, 'must be a number or Date');
}

promises.constants = constants;

export function readFile(path, options, callback) {
  if (typeof options === 'function') {
    callback = options;
    options = undefined;
  }
  requireCallback(callback);
  nodeify(promises.readFile(path, options), callback);
}

export function writeFile(path, data, options, callback) {
  if (typeof options === 'function') {
    callback = options;
    options = undefined;
  }
  requireCallback(callback);
  nodeify(promises.writeFile(path, data, options), callback);
}

export function appendFile(path, data, options, callback) {
  if (typeof options === 'function') {
    callback = options;
    options = undefined;
  }
  requireCallback(callback);
  nodeify(promises.appendFile(path, data, options), callback);
}

export function stat(path, options, callback) {
  if (typeof options === 'function') {
    callback = options;
  }
  requireCallback(callback);
  nodeify(promises.stat(path), callback);
}

export function lstat(path, options, callback) {
  if (typeof options === 'function') {
    callback = options;
  }
  requireCallback(callback);
  nodeify(promises.lstat(path), callback);
}

export function readdir(path, options, callback) {
  if (typeof options === 'function') {
    callback = options;
    options = undefined;
  }
  requireCallback(callback);
  nodeify(promises.readdir(path, options), callback);
}

export function mkdir(path, options, callback) {
  if (typeof options === 'function') {
    callback = options;
    options = undefined;
  }
  requireCallback(callback);
  nodeify(promises.mkdir(path, options), (error, value) => callback(error, value));
}

export function rmdir(path, options, callback) {
  if (typeof options === 'function') {
    callback = options;
    options = undefined;
  }
  requireCallback(callback);
  nodeify(promises.rmdir(path, options), callback);
}

export function rm(path, options, callback) {
  if (typeof options === 'function') {
    callback = options;
    options = undefined;
  }
  requireCallback(callback);
  nodeify(promises.rm(path, options), callback);
}

export function unlink(path, callback) {
  requireCallback(callback);
  nodeify(promises.unlink(path), callback);
}

export function rename(oldPath, newPath, callback) {
  requireCallback(callback);
  nodeify(promises.rename(oldPath, newPath), callback);
}

export function copyFile(src, dest, mode, callback) {
  if (typeof mode === 'function') {
    callback = mode;
    mode = 0;
  }
  requireCallback(callback);
  nodeify(promises.copyFile(src, dest, mode), callback);
}

export function cp(src, dest, options, callback) {
  if (typeof options === 'function') {
    callback = options;
    options = undefined;
  }
  requireCallback(callback);
  nodeify(promises.cp(src, dest, options), callback);
}

export function access(path, mode, callback) {
  if (typeof mode === 'function') {
    callback = mode;
    mode = constants.F_OK;
  }
  requireCallback(callback);
  nodeify(promises.access(path, mode), callback);
}

export function exists(path, callback) {
  requireCallback(callback);
  promises.access(path).then(
    () => callback(true),
    () => callback(false),
  );
}

export function realpath(path, options, callback) {
  if (typeof options === 'function') {
    callback = options;
  }
  requireCallback(callback);
  nodeify(promises.realpath(path), callback);
}

export function readlink(path, options, callback) {
  if (typeof options === 'function') {
    callback = options;
  }
  requireCallback(callback);
  nodeify(promises.readlink(path), callback);
}

export function symlink(target, path, type, callback) {
  if (typeof type === 'function') {
    callback = type;
  }
  requireCallback(callback);
  nodeify(promises.symlink(target, path), callback);
}

export function truncate(path, length, callback) {
  if (typeof length === 'function') {
    callback = length;
    length = 0;
  }
  requireCallback(callback);
  nodeify(promises.truncate(path, length), callback);
}

export function chmod(path, mode, callback) {
  requireCallback(callback);
  nodeify(promises.chmod(path, mode), callback);
}

export function chown(path, uid, gid, callback) {
  requireCallback(callback);
  nodeify(promises.chown(path, uid, gid), callback);
}

export function link(existingPath, newPath, callback) {
  requireCallback(callback);
  nodeify(promises.link(existingPath, newPath), callback);
}

export function utimes(path, atime, mtime, callback) {
  requireCallback(callback);
  nodeify(promises.utimes(path, atime, mtime), callback);
}

function notImplemented(name, alternative) {
  return function () {
    const error = new Error(`jsz does not implement ${name}; use ${alternative}`);
    error.code = 'ERR_METHOD_NOT_IMPLEMENTED';
    throw error;
  };
}

function notImplementedAsync(name, alternative) {
  return function () {
    const error = new Error(`jsz does not implement ${name}; use ${alternative}`);
    error.code = 'ERR_METHOD_NOT_IMPLEMENTED';
    return Promise.reject(error);
  };
}

export const readFileSync = notImplemented('fs.readFileSync', 'fs.promises.readFile');
export const writeFileSync = notImplemented('fs.writeFileSync', 'fs.promises.writeFile');
export const appendFileSync = notImplemented('fs.appendFileSync', 'fs.promises.appendFile');
export const copyFileSync = notImplemented('fs.copyFileSync', 'fs.promises.copyFile');
export const cpSync = notImplemented('fs.cpSync', 'fs.promises.cp');
export const renameSync = notImplemented('fs.renameSync', 'fs.promises.rename');
export const rmSync = notImplemented('fs.rmSync', 'fs.promises.rm');
export const rmdirSync = notImplemented('fs.rmdirSync', 'fs.promises.rmdir');
export const unlinkSync = notImplemented('fs.unlinkSync', 'fs.promises.unlink');
export const mkdirSync = notImplemented('fs.mkdirSync', 'fs.promises.mkdir');
export const mkdtempSync = notImplemented('fs.mkdtempSync', 'fs.promises.mkdtemp');
export const readdirSync = notImplemented('fs.readdirSync', 'fs.promises.readdir');
export const statSync = notImplemented('fs.statSync', 'fs.promises.stat');
export const lstatSync = notImplemented('fs.lstatSync', 'fs.promises.lstat');
export const fstatSync = notImplemented('fs.fstatSync', 'fs.fstat');
export const accessSync = notImplemented('fs.accessSync', 'fs.promises.access');
export const realpathSync = notImplemented('fs.realpathSync', 'fs.promises.realpath');
export const chmodSync = notImplemented('fs.chmodSync', 'fs.promises.chmod');
export const chownSync = notImplemented('fs.chownSync', 'fs.promises.chown');
export const utimesSync = notImplemented('fs.utimesSync', 'fs.promises.utimes');
export const symlinkSync = notImplemented('fs.symlinkSync', 'fs.promises.symlink');
export const readlinkSync = notImplemented('fs.readlinkSync', 'fs.promises.readlink');
export const linkSync = notImplemented('fs.linkSync', 'fs.promises.link');
export const openSync = notImplemented('fs.openSync', 'fs.open');
export const closeSync = notImplemented('fs.closeSync', 'fs.close');
export const readSync = notImplemented('fs.readSync', 'fs.read');
export const writeSync = notImplemented('fs.writeSync', 'fs.write');
export const fsyncSync = notImplemented('fs.fsyncSync', 'fs.fsync');
export const truncateSync = notImplemented('fs.truncateSync', 'fs.promises.truncate');

realpath.native = realpath;

export function mkdtemp(prefix, callback) {
  requireCallback(callback);
  nodeify(promises.mkdtemp(prefix), callback);
}

export function open(path, flags, mode, callback) {
  if (typeof mode === 'function') {
    callback = mode;
    mode = undefined;
  }
  // Node validates flags synchronously for the callback API.
  const flag = normalizeFlags(flags) ?? 'r';
  requireCallback(callback);
  nodeify(openFd(path, flag, mode), callback);
}

export function close(fd, callback) {
  requireCallback(callback);
  nodeify(closeFd(fd), callback);
}

export function read(fd, buffer, offset, length, position, callback) {
  requireCallback(callback);
  nodeify(readInto(fd, buffer, offset, length, position), (error, result) =>
    error ? callback(error) : callback(null, result.bytesRead, result.buffer),
  );
}

export function write(fd, data, offset, length, position, callback) {
  if (typeof data === 'string') {
    // fs.write(fd, string[, position[, encoding]], callback)
    let at = offset;
    let encoding = length;
    let cb = position;
    if (typeof at === 'function') {
      cb = at;
      at = undefined;
      encoding = undefined;
    } else if (typeof encoding === 'function') {
      cb = encoding;
      encoding = undefined;
    }
    requireCallback(cb);
    nodeify(writeString(fd, data, at, encoding), (error, result) =>
      error ? cb(error) : cb(null, result.bytesWritten, result.string),
    );
    return;
  }

  requireCallback(callback);
  nodeify(writeBuffer(fd, data, offset, length, position), (error, result) =>
    error ? callback(error) : callback(null, result.bytesWritten, result.buffer),
  );
}

export function fsync(fd, callback) {
  requireCallback(callback);
  nodeify(fsyncFd(fd), callback);
}

export function fstat(fd, options, callback) {
  if (typeof options === 'function') {
    callback = options;
    options = undefined;
  }
  requireCallback(callback);
  nodeify(fstatFd(fd), callback);
}

export const watch = notImplementedAsync('fs.watch', 'fs.watchFile');
export const createReadStream = notImplemented('fs.createReadStream', 'fs.promises.readFile');
export const createWriteStream = notImplemented('fs.createWriteStream', 'fs.promises.writeFile');

const namespace = {
  constants,
  Stats,
  Dirent,
  promises,
  readFile,
  writeFile,
  appendFile,
  stat,
  lstat,
  readdir,
  mkdir,
  rmdir,
  rm,
  unlink,
  rename,
  copyFile,
  cp,
  access,
  exists,
  realpath,
  readlink,
  symlink,
  truncate,
  chmod,
  chown,
  link,
  utimes,
  readFileSync,
  writeFileSync,
  appendFileSync,
  copyFileSync,
  cpSync,
  renameSync,
  rmSync,
  rmdirSync,
  unlinkSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  statSync,
  lstatSync,
  fstatSync,
  accessSync,
  realpathSync,
  chmodSync,
  chownSync,
  utimesSync,
  symlinkSync,
  readlinkSync,
  linkSync,
  openSync,
  closeSync,
  readSync,
  writeSync,
  fsyncSync,
  truncateSync,
  mkdtemp,
  open,
  close,
  read,
  write,
  fsync,
  fstat,
  watch,
  createReadStream,
  createWriteStream,
};

export default namespace;
