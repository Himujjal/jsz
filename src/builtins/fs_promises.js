// Promise-facing view of `node:fs`. Shares the same implementations so
// callbacks and `fs/promises` observe identical bytes and errors.

import fs from 'node:fs';

const promises = fs.promises;

export const constants = fs.constants;
export const Stats = fs.Stats;
export const Dirent = fs.Dirent;

export const readFile = promises.readFile;
export const writeFile = promises.writeFile;
export const appendFile = promises.appendFile;
export const stat = promises.stat;
export const lstat = promises.lstat;
export const readdir = promises.readdir;
export const mkdir = promises.mkdir;
export const rmdir = promises.rmdir;
export const rm = promises.rm;
export const unlink = promises.unlink;
export const rename = promises.rename;
export const copyFile = promises.copyFile;
export const cp = promises.cp;
export const access = promises.access;
export const realpath = promises.realpath;
export const readlink = promises.readlink;
export const symlink = promises.symlink;
export const truncate = promises.truncate;
export const chmod = promises.chmod;
export const chown = promises.chown;
export const link = promises.link;
export const utimes = promises.utimes;

function unsupported(name) {
  return function () {
    const error = new Error(`jsz does not implement ${name}`);
    error.code = 'ERR_METHOD_NOT_IMPLEMENTED';
    return Promise.reject(error);
  };
}

export const mkdtemp = promises.mkdtemp;
export const open = promises.open;
export const watch = unsupported('fs.promises.watch');

export default promises;
