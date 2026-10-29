// Node-compatible `console` over the native writers from `builtins.zig`.
// Formatting lives here so `%s`/`%d`/`%o` match `util.format`.

import { format, inspect } from 'node:util';

// Bootstrap imports this module before replacing the global, so the native
// object is still the one installed at context creation.
const native = globalThis.console;
if (typeof native?.log !== 'function' || typeof native?.error !== 'function') {
  throw new Error('jsz: console must be evaluated before the global console is replaced');
}

function stdout(text) {
  native.log(text);
}

function stderr(text) {
  native.error(text);
}

// QuickJS stacks start with the first frame, so there is no `Error` header to
// drop. Frames owned by this file are noise in `trace`/`assert` output.
function stack() {
  const text = new Error().stack;
  if (typeof text !== 'string') return '';
  return text
    .split('\n')
    .filter((line) => !line.includes('(node:console:'))
    .join('\n')
    .replace(/\n+$/, '');
}

function write(stream, args) {
  stream(format(...args));
}

function log(...args) {
  write(stdout, args);
}

function info(...args) {
  write(stdout, args);
}

function debug(...args) {
  write(stdout, args);
}

function warn(...args) {
  write(stderr, args);
}

function error(...args) {
  write(stderr, args);
}

function trace(...args) {
  stdout(`Trace: ${format(...args)}`);
  const text = stack();
  if (text.length > 0) stdout(text);
}

function dir(object, options) {
  stdout(inspect(object, options));
}

function assert(value, ...args) {
  if (value) return;
  const detail = args.length > 0 ? `: ${format(...args)}` : '';
  stderr(`Assertion failed${detail}`);
  const text = stack();
  if (text.length > 0) stderr(text);
}

const timers = new Map();

function labelOf(label) {
  return label === undefined ? 'default' : `${label}`;
}

function time(label) {
  const name = labelOf(label);
  if (timers.has(name)) {
    stderr(`Warning: Label '${name}' already exists for console.time()`);
    return;
  }
  timers.set(name, performance.now());
}

function timeEnd(label) {
  const name = labelOf(label);
  const start = timers.get(name);
  if (start === undefined) {
    stderr(`Warning: No such label '${name}' for console.timeEnd()`);
    return;
  }
  timers.delete(name);
  // Node prints three decimals, e.g. `t: 0.082ms`.
  stdout(`${name}: ${(performance.now() - start).toFixed(3)}ms`);
}

const console = {
  log,
  info,
  warn,
  error,
  debug,
  trace,
  dir,
  assert,
  time,
  timeEnd,
};

export { log, info, warn, error, debug, trace, dir, assert, time, timeEnd };
export default console;
