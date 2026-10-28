// Synchronous and asynchronous subsets of Node.js 22 `node:child_process`.
// `spawnSync`/`execSync`/`execFileSync` block the JS task; `spawn` hands the
// process to a zio coordinator and reports `data`/`end`/`exit` back through
// the shared completion queue. Streams, `fork`, and `pipe` are out of scope.

import * as native from 'node:_child_process';
import { Buffer } from 'node:buffer';
import { EventEmitter } from 'node:events';
import process from 'node:process';

const isWindows = process.platform === 'win32';
const defaultMaxBuffer = 1024 * 1024;

function invalidArgType(name, expected, value) {
  const error = new TypeError(`The "${name}" argument must be of type ${expected}. Received ${typeof value}`);
  error.code = 'ERR_INVALID_ARG_TYPE';
  return error;
}

function invalidArgValue(name, value, reason) {
  const error = new TypeError(`The argument '${name}' ${reason}. Received ${String(value)}`);
  error.code = 'ERR_INVALID_ARG_VALUE';
  return error;
}

function validateString(value, name) {
  if (typeof value !== 'string') throw invalidArgType(name, 'string', value);
}

/// `spawnSync(command, args, options)`: an object in the `args` slot is the
/// options object, matching Node's optional-argument juggling.
function splitArguments(args, options) {
  if (args !== null && typeof args === 'object' && !Array.isArray(args)) {
    if (options !== undefined) throw invalidArgType('args', 'Array', args);
    return { args: [], options: args };
  }
  if (args === undefined || args === null) return { args: [], options: options ?? {} };
  if (!Array.isArray(args)) throw invalidArgType('args', 'Array', args);
  return { args, options: options ?? {} };
}

function normalizeEncoding(encoding) {
  if (encoding === undefined || encoding === null) return null;
  const name = String(encoding).toLowerCase();
  if (name === 'buffer') return null;
  if (!Buffer.isEncoding(name)) throw invalidArgValue('encoding', encoding, 'is invalid encoding');
  return name;
}

function normalizeStdio(stdio) {
  if (typeof stdio === 'string') return [stdio, stdio, stdio];
  if (Array.isArray(stdio)) {
    const entries = [stdio[0], stdio[1], stdio[2]];
    return entries.map((entry) => (typeof entry === 'string' ? entry : 'pipe'));
  }
  return ['pipe', 'pipe', 'pipe'];
}

function normalizeEnv(env) {
  if (env === undefined || env === null) return null;
  if (typeof env !== 'object') throw invalidArgType('options.env', 'Object', env);

  const pairs = [];
  for (const key of Object.keys(env)) {
    const value = env[key];
    if (value === undefined) continue;
    pairs.push([key, `${value}`]);
  }
  return pairs;
}

function normalizeInput(input, encoding) {
  if (input === undefined || input === null) return null;
  if (typeof input === 'string') return Buffer.from(input, encoding || 'utf8');
  if (ArrayBuffer.isView(input)) return input;
  if (input instanceof ArrayBuffer) return new Uint8Array(input);
  return null;
}

function normalizeMaxBuffer(maxBuffer) {
  if (typeof maxBuffer !== 'number' || !Number.isFinite(maxBuffer) || maxBuffer < 1) {
    return defaultMaxBuffer;
  }
  return Math.floor(maxBuffer);
}

const SIGNAL_NAMES = new Set([
  'SIGHUP',
  'SIGINT',
  'SIGQUIT',
  'SIGILL',
  'SIGTRAP',
  'SIGABRT',
  'SIGBUS',
  'SIGFPE',
  'SIGKILL',
  'SIGUSR1',
  'SIGSEGV',
  'SIGUSR2',
  'SIGPIPE',
  'SIGALRM',
  'SIGTERM',
  'SIGCHLD',
  'SIGCONT',
  'SIGSTOP',
  'SIGTSTP',
  'SIGTTIN',
  'SIGTTOU',
  'SIGURG',
  'SIGXCPU',
  'SIGXFSZ',
  'SIGVTALRM',
  'SIGPROF',
  'SIGWINCH',
  'SIGIO',
  'SIGSYS',
]);

function unknownSignal(signal) {
  const error = new TypeError(`Unknown signal: ${String(signal)}`);
  error.code = 'ERR_UNKNOWN_SIGNAL';
  return error;
}

function normalizeSignal(signal) {
  if (typeof signal === 'number') {
    if (!Number.isInteger(signal) || signal < 0 || signal > 64) throw unknownSignal(signal);
    return signal;
  }
  if (typeof signal === 'string') {
    const name = signal.toUpperCase();
    if (!SIGNAL_NAMES.has(name)) throw unknownSignal(signal);
    return name;
  }
  throw unknownSignal(signal);
}

function normalizeTimeout(timeout) {
  if (typeof timeout !== 'number' || !Number.isFinite(timeout) || timeout < 0) return 0;
  return Math.floor(timeout);
}

function normalizeId(value) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) return null;
  return Math.floor(value);
}

function abortSignalError(signal) {
  const reason = signal === null || signal === undefined ? undefined : signal.reason;
  if (reason instanceof Error) return reason;
  const error = new Error(typeof reason === 'string' ? reason : 'The operation was aborted');
  error.name = 'AbortError';
  error.code = 'ABORT_ERR';
  return error;
}

function normalizeOptions(options) {
  const opts = options === undefined || options === null ? {} : options;
  if (typeof opts !== 'object') throw invalidArgType('options', 'Object', opts);

  return {
    cwd: typeof opts.cwd === 'string' ? opts.cwd : null,
    envPairs: normalizeEnv(opts.env),
    stdio: normalizeStdio(opts.stdio),
    input: normalizeInput(opts.input, opts.inputEncoding),
    maxBuffer: normalizeMaxBuffer(opts.maxBuffer),
    encoding: normalizeEncoding(opts.encoding),
    shell: opts.shell,
    timeout: normalizeTimeout(opts.timeout),
    killSignal: normalizeSignal(opts.killSignal === undefined ? 'SIGTERM' : opts.killSignal),
    signal: opts.signal !== null && typeof opts.signal === 'object' ? opts.signal : null,
    uid: normalizeId(opts.uid),
    gid: normalizeId(opts.gid),
    windowsHide: opts.windowsHide === true,
    detached: opts.detached === true,
  };
}

function quoteShellArgument(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

/// Expands `command`/`args` into the file plus argv the native layer spawns.
function buildCommand(command, args, shell) {
  if (!shell) return { file: command, args };

  const shellPath = typeof shell === 'string' ? shell : isWindows ? 'cmd.exe' : '/bin/sh';
  let line = command;
  if (args.length > 0) line += ` ${args.map(quoteShellArgument).join(' ')}`;
  return {
    file: shellPath,
    args: isWindows ? ['/d', '/s', '/c', line] : ['-c', line],
  };
}

function toOutput(bytes, encoding) {
  if (bytes === null || bytes === undefined) return null;
  const buffer = Buffer.from(bytes);
  return encoding === null ? buffer : buffer.toString(encoding);
}

function abortError() {
  const error = new Error('The operation was aborted');
  error.name = 'AbortError';
  error.code = 'ABORT_ERR';
  return error;
}

function spawnError(payload, spawnargs) {
  const error = new Error(payload.message);
  if (payload.name !== undefined) error.name = payload.name;
  error.code = payload.code;
  error.errno = payload.errno;
  error.syscall = payload.syscall;
  error.path = payload.path;
  error.spawnargs = spawnargs;
  return error;
}

/// Runs the native call and converts the plain result into Node's shape.
function runSync(file, args, normalized, shell) {
  const command = buildCommand(file, args, shell);
  const spawnargs = [command.file, ...command.args];

  if (normalized.signal !== null && normalized.signal.aborted) {
    throw abortSignalError(normalized.signal);
  }

  const result = native.spawnSync(command.file, command.args, {
    cwd: normalized.cwd,
    envPairs: normalized.envPairs,
    stdio: normalized.stdio,
    input: normalized.input,
    maxBuffer: normalized.maxBuffer,
    timeout: normalized.timeout,
    killSignal: normalized.killSignal,
    uid: normalized.uid,
    gid: normalized.gid,
    windowsHide: normalized.windowsHide,
    detached: normalized.detached,
  });

  const stdout = toOutput(result.stdout, normalized.encoding);
  const stderr = toOutput(result.stderr, normalized.encoding);
  const error = result.error === null ? null : spawnError(result.error, spawnargs);

  return {
    pid: result.pid,
    output: [null, stdout, stderr],
    stdout,
    stderr,
    status: result.status,
    signal: result.signal,
    error,
  };
}

export function spawnSync(command, args, options) {
  validateString(command, 'file');
  const split = splitArguments(args, options);
  const opts = normalizeOptions(split.options);
  return runSync(command, split.args, opts, opts.shell);
}

function failureMessage(file, args, stderr) {
  const line = [file, ...args].join(' ');
  const detail = stderr === null ? '' : stderr.toString();
  return detail.length > 0 ? `Command failed: ${line}\n${detail}` : `Command failed: ${line}`;
}

export function execFileSync(file, args, options) {
  validateString(file, 'file');
  const split = splitArguments(args, options);
  const opts = normalizeOptions(split.options);
  const result = runSync(file, split.args, opts, opts.shell);

  if (result.error !== null) {
    const error = result.error;
    if (error.code === 'ENOBUFS') error.code = 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER';
    throw error;
  }
  if (result.status !== 0) {
    const error = new Error(failureMessage(file, split.args, result.stderr));
    error.status = result.status;
    error.signal = result.signal;
    error.stdout = result.stdout;
    error.stderr = result.stderr;
    error.pid = result.pid;
    error.output = result.output;
    throw error;
  }
  return result.stdout;
}

export function execSync(command, options) {
  validateString(command, 'command');
  const opts = options === undefined || options === null ? {} : options;
  if (typeof opts !== 'object') throw invalidArgType('options', 'Object', opts);

  const shell = typeof opts.shell === 'string' ? opts.shell : isWindows ? 'cmd.exe' : '/bin/sh';
  const childOptions = { ...opts };
  delete childOptions.shell;

  const args = isWindows ? ['/d', '/s', '/c', command] : ['-c', command];
  return execFileSync(shell, args, childOptions);
}

// ---------------------------------------------------------------------------
// Async surface
// ---------------------------------------------------------------------------

const live = new Map();
let failedSpawnId = 0;

/// Every child lives here until `exit`; dispatch ignores unknown ids.
function emitSafely(emitter, name, ...args) {
  try {
    emitter.emit(name, ...args);
  } catch (error) {
    // Listener errors must not unwind into the native dispatch frame; report
    // them the way an async throw would.
    queueMicrotask(() => {
      throw error;
    });
  }
}

function createOutput(id, stream) {
  const output = new EventEmitter();
  output._id = id;
  output._stream = stream;
  output._encoding = null;
  output._paused = false;
  output._buffered = [];
  output._ended = false;
  output.destroyed = false;
  output.readable = true;

  /// Resumes native reads when the consumer is ready for more.
  output.setEncoding = (encoding) => {
    output._encoding = encoding === undefined || encoding === null ? null : String(encoding);
    return output;
  };

  output.pause = () => {
    if (output._paused) return output;
    output._paused = true;
    native.setPaused(output._id, output._stream, true);
    return output;
  };

  output.resume = () => {
    if (!output._paused) return output;
    output._paused = false;
    native.setPaused(output._id, output._stream, false);

    const pending = output._buffered;
    output._buffered = [];
    for (const chunk of pending) emitSafely(output, 'data', chunk);

    if (output._ended) {
      output._ended = false;
      output.readable = false;
      emitSafely(output, 'end');
    }
    return output;
  };

  output.pipe = (dest, options) => {
    const shouldEnd = options === undefined || options === null || options.end !== false;

    output.on('data', (chunk) => {
      const accepted = dest.write(chunk);
      // `process.stdout` has no `on`/`drain`, so never pause on it.
      if (accepted === false && typeof dest.on === 'function') {
        output.pause();
        dest.on('drain', () => output.resume());
      }
    });

    if (shouldEnd) {
      output.on('end', () => {
        if (typeof dest.end === 'function') dest.end();
      });
    }
    return dest;
  };

  output.destroy = () => {
    output.destroyed = true;
    output.pause();
    emitSafely(output, 'close');
    return output;
  };

  output[Symbol.asyncIterator] = async function* () {
    output.resume();

    const queued = [];
    let ended = false;
    let wake = null;

    const onData = (chunk) => {
      queued.push(chunk);
      if (wake !== null) {
        const resume = wake;
        wake = null;
        resume();
      }
    };
    const onEnd = () => {
      ended = true;
      if (wake !== null) {
        const resume = wake;
        wake = null;
        resume();
      }
    };

    output.on('data', onData);
    output.on('end', onEnd);
    try {
      while (queued.length > 0 || !ended) {
        if (queued.length === 0) {
          await new Promise((resolve) => {
            wake = resolve;
          });
          continue;
        }
        yield queued.shift();
      }
    } finally {
      output.removeListener('data', onData);
      output.removeListener('end', onEnd);
    }
  };

  return output;
}

function toChunk(data, encoding) {
  if (typeof data === 'string') {
    return Buffer.from(data, encoding === undefined || encoding === null ? 'utf8' : encoding);
  }
  if (ArrayBuffer.isView(data)) return data;
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  throw invalidArgType('chunk', 'string, Buffer, or Uint8Array', data);
}

function createStdin(id) {
  const stdin = new EventEmitter();
  stdin.writable = true;
  stdin._needDrain = false;

  stdin.write = (data, encoding, callback) => {
    if (typeof encoding === 'function') {
      callback = encoding;
      encoding = undefined;
    }
    if (!stdin.writable) {
      if (typeof callback === 'function') queueMicrotask(callback);
      return false;
    }

    const status = native.writeStdin(id, toChunk(data, encoding));
    if (typeof callback === 'function') queueMicrotask(callback);

    if (status === 2) {
      stdin.writable = false;
      return false;
    }
    if (status === 1) {
      stdin._needDrain = true;
      return false;
    }
    if (status !== 0) {
      stdin.writable = false;
      return false;
    }
    return true;
  };

  stdin.end = (data, encoding, callback) => {
    if (typeof data === 'function') {
      callback = data;
      data = undefined;
      encoding = undefined;
    } else if (typeof encoding === 'function') {
      callback = encoding;
      encoding = undefined;
    }
    if (data !== undefined && data !== null) stdin.write(data, encoding);
    if (stdin.writable) {
      stdin.writable = false;
      native.endStdin(id);
    }
    if (typeof callback === 'function') queueMicrotask(callback);
    return stdin;
  };

  stdin.destroy = () => stdin.end();

  return stdin;
}

class ChildProcess extends EventEmitter {
  constructor(id, pid, spawnfile, spawnargs) {
    super();
    this._id = id;
    this.pid = pid;
    this.spawnfile = spawnfile;
    this.spawnargs = spawnargs;
    this.exitCode = null;
    this.signalCode = null;
    this.killed = false;
    // Child-specific facade: `data`/`end` events with bounded native reads.
    this.stdout = createOutput(id, 0);
    this.stderr = createOutput(id, 1);
    this.stdin = createStdin(id);
  }

  kill(signal = 'SIGTERM') {
    const normalized = normalizeSignal(signal);
    if (normalized === 0) return this.exitCode === null && this.signalCode === null;
    const sent = native.kill(this._id, normalized);
    if (sent) this.killed = true;
    return sent;
  }

  ref() {
    native.setRef(this._id, true);
    return this;
  }

  unref() {
    native.setRef(this._id, false);
    return this;
  }
}

/// Native trampoline: `(id, event, stream, payload)` for one child event.
function dispatch(id, event, stream, payload) {
  const child = live.get(id);
  if (!child) return;

  if (event === 'data') {
    const output = stream === 0 ? child.stdout : child.stderr;
    const bytes = Buffer.from(payload);
    const chunk = output._encoding === null ? bytes : bytes.toString(output._encoding);
    if (output._paused) {
      output._buffered.push(chunk);
      return;
    }
    emitSafely(output, 'data', chunk);
    return;
  }

  if (event === 'end') {
    const output = stream === 0 ? child.stdout : child.stderr;
    if (output._paused) {
      output._ended = true;
      return;
    }
    output.readable = false;
    emitSafely(output, 'end');
    return;
  }

  if (event === 'drain') {
    const stdin = child.stdin;
    if (stdin._needDrain) {
      stdin._needDrain = false;
      emitSafely(stdin, 'drain');
    }
    return;
  }

  if (event === 'exit') {
    child.exitCode = payload.code;
    child.signalCode = payload.signal;
    live.delete(id);
    emitSafely(child, 'exit', payload.code, payload.signal);
    queueMicrotask(() => emitSafely(child, 'close', payload.code, payload.signal));
    return;
  }

  const error = spawnError(payload, child.spawnargs);
  live.delete(id);
  emitSafely(child, 'error', error);
  queueMicrotask(() => emitSafely(child, 'close', null, null));
}

export function spawn(command, args, options) {
  validateString(command, 'file');
  const split = splitArguments(args, options);
  const opts = normalizeOptions(split.options);
  const built = buildCommand(command, split.args, opts.shell);
  const spawnargs = [built.file, ...built.args];

  // Node reports a pre-aborted spawn asynchronously on the returned child.
  if (opts.signal !== null && opts.signal.aborted) {
    failedSpawnId -= 1;
    const id = failedSpawnId;
    const child = new ChildProcess(id, undefined, built.file, spawnargs);
    live.set(id, child);
    const payload = {
      name: 'AbortError',
      code: 'ABORT_ERR',
      message: 'The operation was aborted',
      errno: -1,
      syscall: 'spawn',
      path: built.file,
    };
    queueMicrotask(() => dispatch(id, 'error', -1, payload));
    return child;
  }

  const result = native.spawn(
    built.file,
    built.args,
    {
      cwd: opts.cwd,
      envPairs: opts.envPairs,
      stdio: opts.stdio,
      timeout: opts.timeout,
      killSignal: opts.killSignal,
      uid: opts.uid,
      gid: opts.gid,
      windowsHide: opts.windowsHide,
      detached: opts.detached,
    },
    dispatch,
  );

  if (result.error !== undefined && result.error !== null) {
    // Node still returns a ChildProcess and reports the failure asynchronously.
    failedSpawnId -= 1;
    const id = failedSpawnId;
    const child = new ChildProcess(id, undefined, built.file, spawnargs);
    live.set(id, child);
    queueMicrotask(() => dispatch(id, 'error', -1, result.error));
    return child;
  }

  const child = new ChildProcess(
    result.id,
    result.pid === null ? undefined : result.pid,
    built.file,
    spawnargs,
  );
  live.set(result.id, child);

  if (opts.timeout > 0) {
    const timer = setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill(opts.killSignal);
    }, opts.timeout);
    child._timeoutTimer = timer;
    child.once('exit', () => clearTimeout(timer));
    child.once('error', () => clearTimeout(timer));
  }

  if (opts.signal !== null && !opts.signal.aborted) {
    const onAbort = () => {
      child._aborted = true;
      // Emitting without a listener would throw inside the native dispatch.
      if (child.listenerCount('error') > 0) {
        const error = abortError();
        error.killed = true;
        emitSafely(child, 'error', error);
      }
      child.kill(opts.killSignal);
    };
    opts.signal.addEventListener('abort', onAbort, { once: true });
    const removeAbort = () => opts.signal.removeEventListener('abort', onAbort);
    child.once('exit', removeAbort);
    child.once('error', removeAbort);
  }

  queueMicrotask(() => emitSafely(child, 'spawn'));
  return child;
}

function splitExecArguments(args, options, callback) {
  if (typeof args === 'function') return { args: [], options: undefined, callback: args };
  if (Array.isArray(args)) {
    if (typeof options === 'function') return { args, options: undefined, callback: options };
    return { args, options, callback };
  }
  if (args !== null && typeof args === 'object') {
    if (typeof options === 'function') return { args: [], options: args, callback: options };
    return { args: [], options: args, callback };
  }
  if (args === undefined || args === null) {
    if (typeof options === 'function') return { args: [], options: undefined, callback: options };
    return { args: [], options, callback };
  }
  throw invalidArgType('args', 'Array', args);
}

function execEncoding(options) {
  return options.encoding === undefined ? 'utf8' : options.encoding;
}

function runExec(file, args, options, callback, display) {
  const opts = options === undefined || options === null ? {} : options;
  if (typeof opts !== 'object') throw invalidArgType('options', 'Object', opts);
  if (typeof callback !== 'function') throw invalidArgType('callback', 'function', callback);

  const encoding = normalizeEncoding(execEncoding(opts));
  const maxBuffer = normalizeMaxBuffer(opts.maxBuffer);

  // Collect raw Buffers so `maxBuffer` counts bytes; decode at the end.
  const spawnOptions = { ...opts };
  delete spawnOptions.encoding;

  const stdoutChunks = [];
  const stderrChunks = [];
  let stdoutLength = 0;
  let stderrLength = 0;
  let done = false;

  const finish = (error, stdout, stderr) => {
    if (done) return;
    done = true;
    callback(error, stdout, stderr);
  };

  const decode = (buffer) => (encoding === null ? buffer : buffer.toString(encoding));

  const child = spawn(file, args, spawnOptions);
  child.on('error', (error) => {
    // Node's exec callback receives the documented shape even for spawn errors.
    if (error.code !== 'ABORT_ERR') {
      if (error.killed === undefined) error.killed = false;
      if (error.signal === undefined) error.signal = null;
    }
    if (error.stdout === undefined) error.stdout = decode(Buffer.alloc(0));
    if (error.stderr === undefined) error.stderr = decode(Buffer.alloc(0));
    if (error.output === undefined) error.output = [null, error.stdout, error.stderr];
    finish(error, error.stdout, error.stderr);
  });

  const overflow = (streamName) => {
    if (done) return;
    child.kill();
    const error = new Error(`${streamName} maxBuffer length exceeded`);
    error.code = 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER';
    error.killed = true;
    finish(error);
  };

  child.stdout.on('data', (chunk) => {
    if (done) return;
    stdoutChunks.push(chunk);
    stdoutLength += chunk.length;
    if (stdoutLength > maxBuffer) overflow('stdout');
  });

  child.stderr.on('data', (chunk) => {
    if (done) return;
    stderrChunks.push(chunk);
    stderrLength += chunk.length;
    if (stderrLength > maxBuffer) overflow('stderr');
  });

  child.on('close', (code, signal) => {
    if (done) return;

    const stdout = Buffer.concat(stdoutChunks, stdoutLength);
    const stderr = Buffer.concat(stderrChunks, stderrLength);

    if (child._aborted) {
      const error = abortError();
      error.killed = true;
      error.stdout = decode(stdout);
      error.stderr = decode(stderr);
      error.pid = child.pid;
      error.output = [null, error.stdout, error.stderr];
      finish(error, error.stdout, error.stderr);
      return;
    }

    if (code !== 0 || signal !== null) {
      const detail = stderr.toString();
      const message = detail.length > 0
        ? `Command failed: ${display}\n${detail}`
        : `Command failed: ${display}`;
      const error = new Error(message);
      error.code = code;
      error.status = code;
      error.signal = signal;
      error.stdout = decode(stdout);
      error.stderr = decode(stderr);
      error.killed = child.killed;
      error.pid = child.pid;
      error.output = [null, error.stdout, error.stderr];
      finish(error, error.stdout, error.stderr);
      return;
    }

    finish(null, decode(stdout), decode(stderr));
  });

  return child;
}

export function execFile(file, args, options, callback) {
  validateString(file, 'file');
  const split = splitExecArguments(args, options, callback);
  if (typeof split.callback !== 'function') {
    throw invalidArgType('callback', 'function', split.callback);
  }

  const display = [file, ...split.args].join(' ');
  return runExec(file, split.args, split.options ?? {}, split.callback, display);
}

export function exec(command, options, callback) {
  validateString(command, 'command');
  if (typeof options === 'function') {
    callback = options;
    options = undefined;
  }
  if (typeof callback !== 'function') throw invalidArgType('callback', 'function', callback);

  const opts = options === undefined || options === null ? {} : options;
  if (typeof opts !== 'object') throw invalidArgType('options', 'Object', opts);

  const shell = typeof opts.shell === 'string' ? opts.shell : isWindows ? 'cmd.exe' : '/bin/sh';
  const args = isWindows ? ['/d', '/s', '/c', command] : ['-c', command];
  const childOptions = { ...opts };
  delete childOptions.shell;

  return runExec(shell, args, childOptions, callback, command);
}

export { ChildProcess };

export default { spawn, spawnSync, exec, execFile, execSync, execFileSync, ChildProcess };
