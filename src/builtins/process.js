// Node-compatible `process` built on `node:_process`. Native calls return plain
// data; every object shape and every thrown error is defined here.

import * as native from 'node:_process';
import { Buffer } from 'node:buffer';

const platform = native.platform();
const arch = native.arch();
const argv = native.argv();
const pid = native.pid();
const ppid = native.ppid();

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

function memoryUsage() {
  // Only rss is observable; QuickJS heap accounting is not exposed yet.
  return {
    rss: native.memoryUsage(),
    heapTotal: 0,
    heapUsed: 0,
    external: 0,
    arrayBuffers: 0,
  };
}

function umask(mask) {
  if (mask === undefined) return native.umask(-1);
  if (typeof mask !== 'number' || !Number.isInteger(mask)) {
    throw invalidArgType('mask', 'integer', mask);
  }
  if (mask < 0 || mask > 0o777) {
    const error = new RangeError(`The value of "mask" is out of range. It must be >= 0 && <= 511. Received ${mask}`);
    error.code = 'ERR_OUT_OF_RANGE';
    throw error;
  }
  return native.umask(mask);
}

// QuickJS has one job queue, so nextTick shares it with promise reactions and
// Node's "nextTick runs before promise callbacks" ordering is not guaranteed.
// FIFO within a single tick still matches Node.
function nextTick(callback, ...args) {
  if (typeof callback !== 'function') throw invalidArgType('callback', 'function', callback);
  queueMicrotask(() => callback(...args));
}

function emitWarning(warning, type, code) {
  let name = 'Warning';
  let message;
  if (warning instanceof Error) {
    message = warning.message;
    if (warning.name) name = warning.name;
    if (code === undefined) code = warning.code;
  } else if (typeof warning === 'string') {
    message = warning;
  } else {
    throw invalidArgType('warning', 'string or an instance of Error', warning);
  }
  if (typeof type === 'string' && type.length > 0) name = type;
  const prefix = typeof code === 'string' && code.length > 0 ? `[${code}] ` : '';
  stderr.write(`(node:${pid}) ${prefix}${name}: ${message}\n`);
}

function writeChunk(nativeWrite, chunk, encoding) {
  if (typeof chunk === 'string') {
    if (encoding === undefined || encoding === null) {
      nativeWrite(chunk);
      return;
    }
    const name = `${encoding}`.toLowerCase();
    if (name === 'utf8' || name === 'utf-8') {
      nativeWrite(chunk);
      return;
    }
    nativeWrite(Buffer.from(chunk, name));
    return;
  }
  if (chunk instanceof Uint8Array) {
    nativeWrite(chunk);
    return;
  }
  throw invalidArgType('chunk', 'string or an instance of Buffer or Uint8Array', chunk);
}

function createStream(nativeWrite, fd) {
  return {
    fd,
    isTTY: false,
    columns: 80,
    rows: 24,
    write(chunk, encoding, callback) {
      if (typeof encoding === 'function') {
        callback = encoding;
        encoding = undefined;
      }
      if (callback !== undefined && callback !== null && typeof callback !== 'function') {
        throw invalidArgType('callback', 'function', callback);
      }
      writeChunk(nativeWrite, chunk, encoding);
      if (callback !== undefined && callback !== null) {
        queueMicrotask(() => callback());
      }
      return true;
    },
  };
}

const stdout = createStream(native.writeOut, 1);
const stderr = createStream(native.writeErr, 2);

let exitCode = 0;

const listeners = new Map();
const trampolines = new Map();
const installed = new Set();

// One Zig trampoline per native event; the registry stays here so `off`,
// `once`, and `removeAllListeners` never cross the boundary.
function signalHook(label) {
  return {
    set: (listener) => native.setSignalHook(label, listener),
    clear: () => native.clearSignalHook(label),
  };
}

const nativeHooks = {
  exit: { set: native.setExitHook, clear: native.clearExitHook },
  SIGINT: signalHook('SIGINT'),
  SIGTERM: signalHook('SIGTERM'),
  SIGHUP: signalHook('SIGHUP'),
  uncaughtException: { set: native.setUncaughtHook, clear: native.clearUncaughtHook },
};

function validateEventName(event) {
  if (typeof event !== 'string' && typeof event !== 'symbol') {
    throw invalidArgType('eventName', 'string or symbol', event);
  }
}

function validateListener(listener) {
  if (typeof listener !== 'function') {
    throw invalidArgType('listener', 'function', listener);
  }
}

function reportListenerError(error) {
  const text = error && error.stack ? error.stack : String(error);
  stderr.write(`${text}\n`);
}

function dispatch(event, value) {
  if (event === 'exit') exitCode = value;
  const list = listeners.get(event);
  if (!list) return;
  for (const entry of list.slice()) {
    if (entry.removed) continue;
    if (entry.once) removeListener(event, entry.listener);
    try {
      entry.listener(value);
    } catch (error) {
      // Listeners must never unwind into QuickJS; Node prints and continues.
      reportListenerError(error);
    }
  }
}

function trampoline(event) {
  let fn = trampolines.get(event);
  if (!fn) {
    fn = (value) => dispatch(event, value);
    trampolines.set(event, fn);
  }
  return fn;
}

function uninstall(event) {
  if (!installed.delete(event)) return;
  const hooks = nativeHooks[event];
  if (hooks) hooks.clear();
}

function addListener(event, listener, once) {
  validateEventName(event);
  validateListener(listener);
  let list = listeners.get(event);
  if (!list) {
    list = [];
    listeners.set(event, list);
  }
  list.push({ listener, once, removed: false });
  if (!installed.has(event)) {
    installed.add(event);
    const hooks = nativeHooks[event];
    if (hooks) hooks.set(trampoline(event));
  }
  return process;
}

function on(event, listener) {
  return addListener(event, listener, false);
}

function once(event, listener) {
  return addListener(event, listener, true);
}

function removeListener(event, listener) {
  validateEventName(event);
  validateListener(listener);
  const list = listeners.get(event);
  if (!list) return process;
  for (let index = list.length - 1; index >= 0; index -= 1) {
    if (list[index].listener === listener) {
      list[index].removed = true;
      list.splice(index, 1);
      break;
    }
  }
  if (list.length === 0) uninstall(event);
  return process;
}

function removeAllListeners(event) {
  if (event === undefined) {
    for (const list of listeners.values()) {
      for (const entry of list) entry.removed = true;
    }
    listeners.clear();
    for (const name of [...installed]) uninstall(name);
    return process;
  }
  validateEventName(event);
  const list = listeners.get(event);
  if (!list) return process;
  for (const entry of list) entry.removed = true;
  listeners.delete(event);
  uninstall(event);
  return process;
}

function listenerCount(event) {
  const list = listeners.get(event);
  return list ? list.length : 0;
}

const execArgv = Object.freeze([]);
const execPath = native.execPath();

let title = 'jsz';

const versions = {
  jsz: native.jszVersion(),
  zig: native.zigVersion(),
  quickjs: native.quickjsVersion(),
  zio: native.zioVersion(),
};

const process = {
  argv,
  env,
  pid,
  ppid,
  platform,
  arch,
  version: native.nodeVersion(),
  versions,
  execArgv,
  execPath,
  stdout,
  stderr,
  cwd: () => native.cwd(),
  chdir,
  exit,
  on,
  once,
  off: removeListener,
  removeListener,
  removeAllListeners,
  listenerCount,
  hrtime,
  uptime: () => native.uptime(),
  memoryUsage,
  umask,
  nextTick,
  emitWarning,
};

Object.defineProperty(process, 'title', {
  enumerable: true,
  configurable: true,
  get: () => title,
  set: (value) => {
    title = `${value}`;
  },
});

Object.defineProperty(process, 'exitCode', {
  enumerable: true,
  configurable: true,
  get: () => exitCode,
  set: (value) => {
    if (value === undefined || value === null) value = 0;
    if (typeof value !== 'number' || !Number.isInteger(value)) {
      throw invalidArgType('code', 'integer', value);
    }
    exitCode = value;
    native.setExitCode(value);
  },
});

const version = process.version;
const cwd = process.cwd;
const uptime = process.uptime;

// Named exports reuse the bindings declared above; redeclaring them with
// `export const` would be a duplicate declaration in module scope.
export {
  pid,
  ppid,
  platform,
  arch,
  version,
  cwd,
  chdir,
  exit,
  on,
  once,
  removeListener,
  removeListener as off,
  removeAllListeners,
  listenerCount,
  hrtime,
  uptime,
  memoryUsage,
  umask,
  nextTick,
  emitWarning,
  execArgv,
  execPath,
  stdout,
  stderr,
  title,
  env,
  argv,
  versions,
};
export default process;
