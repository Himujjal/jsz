// Node-compatible `process` built on `node:_process`. Native calls return plain
// data; every object shape and every thrown error is defined here.

import * as native from 'node:_process';

const platform = native.platform();
const arch = native.arch();
const argv = native.argv();

function invalidArgType(name, expected, actual) {
  const error = new TypeError(`The "${name}" argument must be of type ${expected}. Received ${typeof actual}`);
  error.code = 'ERR_INVALID_ARG_TYPE';
  return error;
}

function validateString(value, name) {
  if (typeof value !== 'string') throw invalidArgType(name, 'string', value);
}

function envKey(key) {
  return typeof key === 'string' && key.length > 0 && !key.includes('=');
}

const env = new Proxy(Object.create(null), {
  get(_target, key) {
    return envKey(key) ? native.envGet(key) : undefined;
  },
  set(_target, key, value) {
    if (!envKey(key)) throw invalidArgType('key', 'string without "="', key);
    native.envSet(key, `${value}`);
    return true;
  },
  deleteProperty(_target, key) {
    if (envKey(key)) native.envDelete(key);
    return true;
  },
  has(_target, key) {
    return envKey(key) && native.envHas(key);
  },
  ownKeys() {
    return native.envKeys();
  },
  getOwnPropertyDescriptor(_target, key) {
    if (!envKey(key)) return undefined;
    const value = native.envGet(key);
    if (value === undefined) return undefined;
    return { value, writable: true, enumerable: true, configurable: true };
  },
});

function chdir(path) {
  validateString(path, 'path');
  const code = native.chdir(path);
  if (code === '') return;
  const cwd = native.cwd();
  const error = new Error(`${code}: no such file or directory, chdir '${cwd}' -> '${path}'`);
  error.code = code;
  error.errno = -2;
  error.syscall = 'chdir';
  error.path = cwd;
  error.dest = path;
  throw error;
}

function hrtime(previous) {
  const nanoseconds = native.elapsedNanoseconds();
  const seconds = Math.floor(nanoseconds / 1e9);
  const remainder = Math.floor(nanoseconds - seconds * 1e9);
  if (!previous) return [seconds, remainder];
  let deltaSeconds = seconds - previous[0];
  let deltaNanoseconds = remainder - previous[1];
  if (deltaNanoseconds < 0) {
    deltaSeconds -= 1;
    deltaNanoseconds += 1e9;
  }
  return [deltaSeconds, deltaNanoseconds];
}

hrtime.bigint = () => BigInt(Math.round(native.elapsedNanoseconds()));

function exit(code = 0) {
  if (typeof code !== 'number' || !Number.isInteger(code)) {
    throw invalidArgType('code', 'integer', code);
  }
  if (code < 0 || code > 255) {
    const error = new RangeError(`The value of "code" is out of range. It must be >= 0 && <= 255. Received ${code}`);
    error.code = 'ERR_OUT_OF_RANGE';
    throw error;
  }
  native.exit(code);
}

const versions = {
  jsz: native.jszVersion(),
  zig: native.zigVersion(),
  quickjs: native.quickjsVersion(),
  zio: native.zioVersion(),
};

const process = {
  argv,
  env,
  pid: native.pid(),
  ppid: native.ppid(),
  platform,
  arch,
  version: native.nodeVersion(),
  versions,
  cwd: () => native.cwd(),
  chdir,
  exit,
  hrtime,
  uptime: () => native.uptime(),
};

const pid = process.pid;
const ppid = process.ppid;
const version = process.version;
const cwd = process.cwd;
const uptime = process.uptime;

// Named exports reuse the bindings declared above; redeclaring them with
// `export const` would be a duplicate declaration in module scope.
export { pid, ppid, platform, arch, version, cwd, chdir, exit, hrtime, uptime, env, argv, versions };
export default process;
