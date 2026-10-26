// Async-only port of Node.js 22 `node:fs`.
// Every operation runs in a zio I/O task through `node:_fs`; nothing blocks the
// JS task. `*Sync` names exist only to fail loudly.

import * as native from 'node:_fs';
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

function invalidEncoding(encoding) {
  return invalidArg('encoding', encoding, 'is not supported (use utf8 or buffer)');
}

function asTextEncoding(encoding) {
  const normalized = String(encoding).toLowerCase().replace(/-/g, '');
  if (normalized === 'utf8') return true;
  if (normalized === 'buffer') return false;
  throw invalidEncoding(encoding);
}

function readOptions(options) {
  if (options == null) return false;
  if (typeof options === 'string') return asTextEncoding(options);
  if (typeof options !== 'object') throw invalidArg('options', options);

  if (options.encoding == null) return false;
  return asTextEncoding(options.encoding);
}

function writeFlag(options) {
  if (options == null) return 'w';
  if (typeof options === 'string') return options;
  if (typeof options !== 'object') throw invalidArg('options', options);
  return typeof options.flag === 'string' ? options.flag : 'w';
}

function writeMode(options) {
  if (options == null || typeof options !== 'object') return 0o666;
  return typeof options.mode === 'number' ? options.mode : 0o666;
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

export class Stats {
  constructor(raw) {
    this.dev = 0;
    this.ino = raw.ino;
    this.mode = raw.mode;
    this.nlink = raw.nlink;
    this.uid = 0;
    this.gid = 0;
    this.rdev = 0;
    this.size = raw.size;
    this.blksize = 4096;
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
  constructor(name, kind) {
    this.name = name;
    Object.defineProperty(this, '_kind', { value: kind });
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

export const promises = {
  async readFile(path, options) {
    return native.readFile(path, readOptions(options));
  },

  async writeFile(path, data, options) {
    const flag = writeFlag(options);
    const bytes = toBytes(data);

    if (flag === 'a' || flag === 'ax' || flag === 'a+') {
      if (flag === 'ax') {
        await native.access(path, constants.F_OK).then(
          () => {
            throw Object.assign(new Error(`EEXIST: file already exists, open '${path}'`), {
              code: 'EEXIST',
              syscall: 'open',
              path,
            });
          },
          () => {},
        );
      }
      return native.appendFile(path, bytes, false);
    }

    if (flag !== 'w' && flag !== 'wx' && flag !== 'w+' && flag !== 'xw') {
      throw invalidArg('flag', flag, 'is not supported');
    }

    return native.writeFile(path, bytes, flag === 'wx' || flag === 'xw');
  },

  async appendFile(path, data, options) {
    return native.appendFile(path, toBytes(data), false);
  },

  async stat(path) {
    return new Stats(await native.stat(path, true));
  },

  async lstat(path) {
    return new Stats(await native.stat(path, false));
  },

  async readdir(path, options) {
    if (options && typeof options === 'object' && options.recursive) {
      const error = new Error('jsz does not implement fs.readdir({ recursive: true })');
      error.code = 'ERR_METHOD_NOT_IMPLEMENTED';
      throw error;
    }
    const raw = await native.readdir(path);
    const withFileTypes = !!(options && typeof options === 'object' && options.withFileTypes);
    if (withFileTypes) return raw.map((entry) => new Dirent(entry.name, entry.kind));
    return raw.map((entry) => entry.name);
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
export const fstatSync = notImplemented('fs.fstatSync', 'fs.promises.stat');
export const accessSync = notImplemented('fs.accessSync', 'fs.promises.access');
export const realpathSync = notImplemented('fs.realpathSync', 'fs.promises.realpath');
export const chmodSync = notImplemented('fs.chmodSync', 'fs.promises.chmod');
export const chownSync = notImplemented('fs.chownSync', 'fs.promises.chown');
export const utimesSync = notImplemented('fs.utimesSync', 'fs.promises.utimes');
export const symlinkSync = notImplemented('fs.symlinkSync', 'fs.promises.symlink');
export const readlinkSync = notImplemented('fs.readlinkSync', 'fs.promises.readlink');
export const linkSync = notImplemented('fs.linkSync', 'fs.promises.link');
export const openSync = notImplemented('fs.openSync', 'fs.promises.open');
export const closeSync = notImplemented('fs.closeSync', 'fs.promises.close');
export const readSync = notImplemented('fs.readSync', 'fs.promises.read');
export const writeSync = notImplemented('fs.writeSync', 'fs.promises.write');
export const fsyncSync = notImplemented('fs.fsyncSync', 'fs.promises.fsync');
export const truncateSync = notImplemented('fs.truncateSync', 'fs.promises.truncate');

realpath.native = realpath;

export const mkdtemp = notImplementedAsync('fs.mkdtemp', 'fs.promises.mkdtemp');
export const open = notImplementedAsync('fs.open', 'fs.promises.open');
export const close = notImplementedAsync('fs.close', 'fs.promises.close');
export const read = notImplementedAsync('fs.read', 'fs.promises.read');
export const write = notImplementedAsync('fs.write', 'fs.promises.write');
export const fsync = notImplementedAsync('fs.fsync', 'fs.promises.fsync');
export const fstat = notImplementedAsync('fs.fstat', 'fs.promises.fstat');
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
  chown,
  link,
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
