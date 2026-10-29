// Pure-JS `node:util`: formatting, inspection, type checks, and the
// callback/promise bridges. `TextEncoder`/`TextDecoder` live at the bottom.

import * as native from 'node:_encoding';
import { Buffer } from 'node:buffer';

const objectToString = Object.prototype.toString;
const getPrototypeOf = Object.getPrototypeOf;
const hasOwnProperty = Object.prototype.hasOwnProperty;

const UTF8 = 'utf-8';
const UTF16LE = 'utf-16le';
const LATIN1 = 'latin1';

function encodingFromLabel(label) {
  const normalized = String(label).toLowerCase();
  switch (normalized) {
    case 'utf-8':
    case 'utf8':
    case 'unicode-1-1-utf-8':
      return UTF8;
    case 'utf-16le':
    case 'utf-16':
    case 'ucs-2':
    case 'ucs2':
    case 'unicode':
      return UTF16LE;
    case 'latin1':
    case 'binary':
    case 'iso-8859-1':
    case 'windows-1252':
    case 'ascii':
      return LATIN1;
    default:
      break;
  }
  const error = new RangeError(`The encoding label provided ('${label}') is invalid.`);
  error.code = 'ERR_ENCODING_NOT_SUPPORTED';
  throw error;
}

function toView(input) {
  if (input === undefined || input === null) return null;
  if (input instanceof ArrayBuffer) return new Uint8Array(input);
  if (ArrayBuffer.isView(input)) return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
  const error = new TypeError('The "input" argument must be an instance of ArrayBuffer or ArrayBufferView.');
  error.code = 'ERR_INVALID_ARG_TYPE';
  throw error;
}

class TextEncoder {
  get encoding() {
    return UTF8;
  }

  encode(input = '') {
    return native.utf8Encode(String(input));
  }

  encodeInto(source, destination) {
    const text = String(source);
    if (!(destination instanceof Uint8Array)) {
      const error = new TypeError('The "destination" argument must be an instance of Uint8Array.');
      error.code = 'ERR_INVALID_ARG_TYPE';
      throw error;
    }

    let read = 0;
    let written = 0;
    while (read < text.length) {
      const first = text.charCodeAt(read);
      let codepoint = first;
      let units = 1;

      if (first >= 0xd800 && first <= 0xdbff) {
        const second = read + 1 < text.length ? text.charCodeAt(read + 1) : 0;
        if (second >= 0xdc00 && second <= 0xdfff) {
          codepoint = 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00);
          units = 2;
        } else {
          codepoint = 0xfffd;
        }
      } else if (first >= 0xdc00 && first <= 0xdfff) {
        codepoint = 0xfffd;
      }

      const size = codepoint < 0x80 ? 1 : codepoint < 0x800 ? 2 : codepoint < 0x10000 ? 3 : 4;
      // A truncated sequence must never reach the destination buffer.
      if (written + size > destination.length) break;

      if (size === 1) {
        destination[written] = codepoint;
      } else if (size === 2) {
        destination[written] = 0xc0 | (codepoint >> 6);
        destination[written + 1] = 0x80 | (codepoint & 0x3f);
      } else if (size === 3) {
        destination[written] = 0xe0 | (codepoint >> 12);
        destination[written + 1] = 0x80 | ((codepoint >> 6) & 0x3f);
        destination[written + 2] = 0x80 | (codepoint & 0x3f);
      } else {
        destination[written] = 0xf0 | (codepoint >> 18);
        destination[written + 1] = 0x80 | ((codepoint >> 12) & 0x3f);
        destination[written + 2] = 0x80 | ((codepoint >> 6) & 0x3f);
        destination[written + 3] = 0x80 | (codepoint & 0x3f);
      }

      read += units;
      written += size;
    }

    return { read, written };
  }
}

class TextDecoder {
  constructor(label = 'utf-8', options = {}) {
    this.encoding = encodingFromLabel(label);
    this.fatal = !!(options && options.fatal);
    this.ignoreBOM = !!(options && options.ignoreBOM);
  }

  decode(input) {
    const bytes = toView(input);
    if (bytes === null) return '';

    let start = 0;
    if (!this.ignoreBOM) {
      if (this.encoding === UTF8 && bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
        start = 3;
      } else if (this.encoding === UTF16LE && bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
        start = 2;
      }
    }

    const payload = start === 0 ? bytes : bytes.subarray(start);
    if (this.encoding === UTF16LE) return native.utf16leDecode(payload);
    if (this.encoding === LATIN1) return native.latin1Decode(payload);

    if (this.fatal && !native.utf8IsValid(payload)) {
      const error = new TypeError('The encoded data was not valid for encoding utf-8');
      error.code = 'ERR_ENCODING_INVALID_ENCODED_DATA';
      throw error;
    }
    return native.utf8Decode(payload);
  }
}

// ---------------------------------------------------------------------------
// Errors and type predicates
// ---------------------------------------------------------------------------

function describeValue(value) {
  if (value === null) return 'null';
  const type = typeof value;
  if (type === 'function') return `function ${value.name || '(anonymous)'}`;
  if (type === 'object') {
    const name = value.constructor && value.constructor.name;
    return name ? `an instance of ${name}` : 'an object';
  }
  return `${type} (${String(value)})`;
}

function invalidArgType(name, expected, value) {
  const error = new TypeError(`The "${name}" argument must be of type ${expected}. Received ${describeValue(value)}`);
  error.code = 'ERR_INVALID_ARG_TYPE';
  return error;
}

function isDate(value) {
  return objectToString.call(value) === '[object Date]';
}

function isRegExp(value) {
  return objectToString.call(value) === '[object RegExp]';
}

function isPromise(value) {
  return objectToString.call(value) === '[object Promise]';
}

function isMap(value) {
  return objectToString.call(value) === '[object Map]';
}

function isSet(value) {
  return objectToString.call(value) === '[object Set]';
}

function isArrayBuffer(value) {
  return objectToString.call(value) === '[object ArrayBuffer]';
}

function isTypedArray(value) {
  return ArrayBuffer.isView(value) && !(value instanceof DataView);
}

function isUint8Array(value) {
  return value instanceof Uint8Array;
}

function isNativeError(value) {
  return objectToString.call(value) === '[object Error]' || value instanceof Error;
}

function isAsyncFunction(value) {
  return objectToString.call(value) === '[object AsyncFunction]';
}

const types = {
  isDate,
  isRegExp,
  isPromise,
  isTypedArray,
  isUint8Array,
  isArrayBuffer,
  isMap,
  isSet,
  isNativeError,
  isAsyncFunction,
};

// ---------------------------------------------------------------------------
// inspect
// ---------------------------------------------------------------------------

const DEFAULT_MAX_ARRAY_LENGTH = 100;
const DEFAULT_BREAK_LENGTH = 80;
const BUFFER_MAX_BYTES = 50;

function inspectOptions(options) {
  let source = options;
  if (source === undefined || source === null) source = {};
  else if (typeof source === 'number') source = { depth: source };
  else if (typeof source === 'boolean') source = { showHidden: source };
  else if (typeof source !== 'object') source = {};

  const depth = source.depth === undefined ? 2 : source.depth;
  let maxArrayLength = source.maxArrayLength;
  if (maxArrayLength === undefined) maxArrayLength = DEFAULT_MAX_ARRAY_LENGTH;
  else if (maxArrayLength === null) maxArrayLength = Infinity;

  return {
    depth: depth === null ? Infinity : depth,
    compact: source.compact === undefined ? 3 : source.compact,
    sorted: !!source.sorted,
    maxArrayLength,
    breakLength: source.breakLength === undefined ? DEFAULT_BREAK_LENGTH : source.breakLength,
    showHidden: !!source.showHidden,
    colors: !!source.colors,
  };
}

function inspect(value, options) {
  const opts = inspectOptions(options);
  return formatValue(value, { opts, seen: [] }, opts.depth, 0);
}

function formatValue(value, ctx, depth, indent) {
  if (value === null) return 'null';

  const type = typeof value;
  switch (type) {
    case 'string':
      return quoteString(value);
    case 'number':
      return Object.is(value, -0) ? '-0' : String(value);
    case 'bigint':
      return `${value}n`;
    case 'boolean':
      return value ? 'true' : 'false';
    case 'undefined':
      return 'undefined';
    case 'symbol':
      return value.toString();
    case 'function':
      return formatFunction(value);
    case 'object':
      break;
    default:
      return String(value);
  }

  // Leaves ignore `depth`; only containers are replaced by a tag.
  if (Buffer.isBuffer(value)) return formatBuffer(value);
  if (isDate(value)) {
    const time = value.getTime();
    return Number.isNaN(time) ? 'Invalid Date' : value.toISOString();
  }
  if (isRegExp(value)) return String(value);
  if (isNativeError(value)) return formatError(value);
  if (isPromise(value)) return depth < 0 ? '[Promise]' : 'Promise { <pending> }';
  if (isArrayBuffer(value)) return depth < 0 ? '[ArrayBuffer]' : `ArrayBuffer { byteLength: ${value.byteLength} }`;
  if (isTypedArray(value)) {
    if (depth < 0) return `[${typedArrayName(value)}]`;
    return formatTypedArray(value, ctx, depth, indent);
  }
  if (objectToString.call(value) === '[object WeakMap]') {
    return depth < 0 ? '[WeakMap]' : 'WeakMap { <items unknown> }';
  }
  if (objectToString.call(value) === '[object WeakSet]') {
    return depth < 0 ? '[WeakSet]' : 'WeakSet { <items unknown> }';
  }

  if (ctx.seen.indexOf(value) !== -1) return '[Circular]';
  if (depth < 0) return depthTag(value);

  if (isMap(value)) return formatMap(value, ctx, depth, indent);
  if (isSet(value)) return formatSet(value, ctx, depth, indent);
  if (Array.isArray(value)) return formatArray(value, ctx, depth, indent);
  return formatObject(value, ctx, depth, indent);
}

function formatFunction(value) {
  const name = typeof value.name === 'string' ? value.name : '';
  let source = '';
  try {
    source = Function.prototype.toString.call(value);
  } catch {
    source = '';
  }
  if (source.startsWith('class')) return name ? `[class ${name}]` : '[class (anonymous)]';
  return name ? `[Function: ${name}]` : '[Function (anonymous)]';
}

function formatBuffer(value) {
  const count = Math.min(value.length, BUFFER_MAX_BYTES);
  const bytes = [];
  for (let index = 0; index < count; index++) {
    bytes.push(value[index].toString(16).padStart(2, '0'));
  }
  let more = '';
  if (value.length > count) {
    const remaining = value.length - count;
    more = ` ... ${remaining} more byte${remaining === 1 ? '' : 's'}`;
  }
  return `<Buffer ${bytes.join(' ')}${more}>`;
}

function formatError(value) {
  const name = typeof value.name === 'string' && value.name ? value.name : 'Error';
  const message = value.message === undefined ? '' : String(value.message);
  const head = message ? `${name}: ${message}` : name;
  const stack = value.stack;
  if (typeof stack === 'string' && stack.length > 0) {
    const newline = stack.indexOf('\n');
    const first = newline === -1 ? stack : stack.slice(0, newline);
    if (first.length > 0 && first.indexOf(name) !== -1) return first;
  }
  return head;
}

function typedArrayName(value) {
  const name = value.constructor && value.constructor.name;
  return typeof name === 'string' && name.length > 0 ? name : 'TypedArray';
}

function formatTypedArray(value, ctx, depth, indent) {
  const entries = [];
  const max = maxArrayItems(value.length, ctx.opts);
  for (let index = 0; index < max; index++) {
    entries.push(formatValue(value[index], ctx, depth - 1, indent + 1));
  }
  if (value.length > max) entries.push(moreItems(value.length - max));
  return renderContainer(`${typedArrayName(value)}(${value.length}) `, '[', ']', entries, ctx, indent);
}

function depthTag(value) {
  if (Array.isArray(value)) return '[Array]';
  if (isMap(value)) return '[Map]';
  if (isSet(value)) return '[Set]';
  const name = constructorName(value);
  return name ? `[${name}]` : '[Object]';
}

function constructorName(value) {
  const proto = getPrototypeOf(value);
  if (proto === null) return null;
  const ctor = proto.constructor;
  if (typeof ctor === 'function' && typeof ctor.name === 'string' && ctor.name.length > 0) return ctor.name;
  return null;
}

function maxArrayItems(length, opts) {
  if (opts.maxArrayLength === Infinity) return length;
  const max = Math.max(0, Math.floor(opts.maxArrayLength));
  return Math.min(length, max);
}

function moreItems(count) {
  return `... ${count} more item${count === 1 ? '' : 's'}`;
}

function formatArray(value, ctx, depth, indent) {
  ctx.seen.push(value);
  try {
    const entries = [];
    const max = maxArrayItems(value.length, ctx.opts);
    for (let index = 0; index < max; index++) {
      if (index in value) entries.push(formatValue(value[index], ctx, depth - 1, indent + 1));
      else entries.push('<1 empty item>');
    }
    if (value.length > max) entries.push(moreItems(value.length - max));
    // `showHidden` exposes the array's own non-enumerable `length`, as Node does.
    if (ctx.opts.showHidden) entries.push(`[length]: ${value.length}`);

    const name = constructorName(value);
    const header = name && name !== 'Array' ? `${name}(${value.length}) ` : '';
    return renderContainer(header, '[', ']', entries, ctx, indent);
  } finally {
    ctx.seen.pop();
  }
}

function formatMap(value, ctx, depth, indent) {
  ctx.seen.push(value);
  try {
    const entries = [];
    for (const entry of value) {
      const key = formatValue(entry[0], ctx, depth - 1, indent + 1);
      const item = formatValue(entry[1], ctx, depth - 1, indent + 1);
      entries.push(`${key} => ${item}`);
    }
    if (ctx.opts.sorted) entries.sort();
    return renderContainer(`Map(${value.size}) `, '{', '}', entries, ctx, indent);
  } finally {
    ctx.seen.pop();
  }
}

function formatSet(value, ctx, depth, indent) {
  ctx.seen.push(value);
  try {
    const entries = [];
    for (const item of value) entries.push(formatValue(item, ctx, depth - 1, indent + 1));
    if (ctx.opts.sorted) entries.sort();
    return renderContainer(`Set(${value.size}) `, '{', '}', entries, ctx, indent);
  } finally {
    ctx.seen.pop();
  }
}

function formatObject(value, ctx, depth, indent) {
  ctx.seen.push(value);
  try {
    const entries = objectEntries(value, ctx, depth, indent);
    let header = '';
    if (getPrototypeOf(value) === null) header = '[Object: null prototype] ';
    else {
      const name = constructorName(value);
      if (name && name !== 'Object') header = `${name} `;
    }
    return renderContainer(header, '{', '}', entries, ctx, indent);
  } finally {
    ctx.seen.pop();
  }
}

function objectEntries(value, ctx, depth, indent) {
  const entries = [];
  for (const key of Reflect.ownKeys(value)) {
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (descriptor === undefined) continue;

    const hidden = !descriptor.enumerable;
    if (hidden && !ctx.opts.showHidden) continue;

    let rendered;
    if (descriptor.get || descriptor.set) {
      if (descriptor.get && descriptor.set) rendered = '[Getter/Setter]';
      else if (descriptor.get) rendered = '[Getter]';
      else rendered = '[Setter]';
    } else {
      rendered = formatValue(descriptor.value, ctx, depth - 1, indent + 1);
    }

    let name;
    if (typeof key === 'symbol') name = `[${key.toString()}]`;
    else if (isIdentifier(key)) name = key;
    else name = quoteString(key);
    if (hidden) name = `[${name}]`;

    entries.push(`${name}: ${rendered}`);
  }
  if (ctx.opts.sorted) entries.sort();
  return entries;
}

function isIdentifier(key) {
  return typeof key === 'string' && /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(key);
}

function renderContainer(header, open, close, entries, ctx, indent) {
  if (entries.length === 0) return `${header}${open}${close}`;

  const single = `${header}${open} ${entries.join(', ')} ${close}`;
  const forceMultiline = ctx.opts.compact === false || ctx.opts.compact === 0;
  const tooWide = indent * 2 + single.length > ctx.opts.breakLength;
  if (!forceMultiline && !tooWide && single.indexOf('\n') === -1) return single;

  const pad = '  '.repeat(indent + 1);
  const closingPad = '  '.repeat(indent);
  return `${header}${open}\n${entries.map((entry) => pad + entry).join(',\n')}\n${closingPad}${close}`;
}

function quoteString(value) {
  let out = "'";
  for (let index = 0; index < value.length; index++) {
    const character = value[index];
    switch (character) {
      case "'":
        out += "\\'";
        break;
      case '\\':
        out += '\\\\';
        break;
      case '\n':
        out += '\\n';
        break;
      case '\r':
        out += '\\r';
        break;
      case '\t':
        out += '\\t';
        break;
      case '\b':
        out += '\\b';
        break;
      case '\f':
        out += '\\f';
        break;
      case '\v':
        out += '\\v';
        break;
      case '\0':
        out += '\\0';
        break;
      default: {
        const code = value.charCodeAt(index);
        if (code < 0x20 || code === 0x7f) out += `\\x${code.toString(16).padStart(2, '0')}`;
        else out += character;
      }
    }
  }
  return `${out}'`;
}

// ---------------------------------------------------------------------------
// format
// ---------------------------------------------------------------------------

function inspectForString(value) {
  if (isDate(value) || isRegExp(value) || isNativeError(value)) return inspect(value, { depth: 0 });
  if (typeof value.toString === 'function' && value.toString !== Object.prototype.toString && value.toString !== Array.prototype.toString) {
    return String(value);
  }
  return inspect(value, { depth: 0 });
}

function formatStringValue(value) {
  if (value === null) return 'null';
  const type = typeof value;
  if (type === 'object') return inspectForString(value);
  if (type === 'function') return String(value);
  if (type === 'number' && Object.is(value, -0)) return '-0';
  if (type === 'bigint') return `${value}n`;
  if (type === 'symbol') return value.toString();
  return String(value);
}

function formatNumber(value) {
  if (typeof value === 'bigint') return `${value}n`;
  let number;
  try {
    number = Number(value);
  } catch {
    return 'NaN';
  }
  return Object.is(number, -0) ? '-0' : String(number);
}

function formatInteger(value) {
  if (typeof value === 'bigint') return `${value}n`;
  let number;
  try {
    number = parseInt(String(value), 10);
  } catch {
    return 'NaN';
  }
  return Object.is(number, -0) ? '-0' : String(number);
}

function formatFloat(value) {
  let number;
  try {
    number = parseFloat(String(value));
  } catch {
    return 'NaN';
  }
  return Object.is(number, -0) ? '-0' : String(number);
}

function formatJson(value) {
  try {
    const json = JSON.stringify(value);
    return json === undefined ? 'undefined' : json;
  } catch {
    return '[Circular]';
  }
}

function format(...args) {
  const template = args[0];
  if (typeof template !== 'string') {
    return args.map((value) => (typeof value === 'string' ? value : inspect(value))).join(' ');
  }
  if (args.length === 1) return template;

  let out = '';
  let next = 1;
  for (let index = 0; index < template.length; index++) {
    const character = template[index];
    if (character !== '%' || index === template.length - 1) {
      out += character;
      continue;
    }

    const specifier = template[++index];
    if (specifier === '%') {
      out += '%';
      continue;
    }
    if (next >= args.length) {
      out += `%${specifier}`;
      continue;
    }

    const value = args[next++];
    switch (specifier) {
      case 's':
        out += formatStringValue(value);
        break;
      case 'd':
        out += formatNumber(value);
        break;
      case 'i':
        out += formatInteger(value);
        break;
      case 'f':
        out += formatFloat(value);
        break;
      case 'j':
        out += formatJson(value);
        break;
      case 'o':
        // Node keeps `%o` compact; only `showHidden` differs from `%O`.
        out += inspect(value, { showHidden: true, depth: 4 });
        break;
      case 'O':
        out += inspect(value, { depth: 4 });
        break;
      case 'c':
        break;
      default:
        out += `%${specifier}`;
        next--;
        break;
    }
  }

  for (; next < args.length; next++) {
    const value = args[next];
    out += ' ' + (typeof value === 'string' ? value : inspect(value));
  }
  return out;
}

// ---------------------------------------------------------------------------
// promisify / callbackify / inherits / deprecate
// ---------------------------------------------------------------------------

const kPromisifyCustom = Symbol.for('nodejs.util.promisify.custom');

function promisify(original) {
  if (typeof original !== 'function') throw invalidArgType('original', 'function', original);

  const custom = original[kPromisifyCustom];
  if (custom !== undefined) {
    if (typeof custom !== 'function') throw invalidArgType('original[kPromisifyCustom]', 'function', custom);
    return custom;
  }

  function fn(...args) {
    const self = this;
    return new Promise((resolve, reject) => {
      let settled = false;
      original.call(self, ...args, (error, ...values) => {
        if (settled) return;
        settled = true;
        if (error) {
          reject(error);
          return;
        }
        if (values.length <= 1) resolve(values[0]);
        else resolve(values);
      });
    });
  }

  Object.setPrototypeOf(fn, getPrototypeOf(original));
  Object.defineProperty(fn, kPromisifyCustom, {
    value: fn,
    configurable: true,
    enumerable: false,
    writable: false,
  });
  return fn;
}

promisify.custom = kPromisifyCustom;

function callbackify(original) {
  if (typeof original !== 'function') throw invalidArgType('original', 'function', original);

  function callbackified(...args) {
    const callback = args.pop();
    if (typeof callback !== 'function') throw invalidArgType('callback', 'function', callback);

    const self = this;
    let result;
    try {
      result = original.apply(self, args);
    } catch (error) {
      throw error;
    }

    Promise.resolve(result).then(
      (value) => {
        callback.call(self, null, value);
      },
      (error) => {
        let reason = error;
        if (!(reason instanceof Error)) {
          reason = new Error(`Promise was rejected with a non-error: ${inspect(reason)}`);
          reason.code = 'ERR_INVALID_ARG_TYPE';
        }
        callback.call(self, reason);
      },
    );
  }

  Object.setPrototypeOf(callbackified, getPrototypeOf(original));
  return callbackified;
}

function inherits(ctor, superCtor) {
  if (typeof ctor !== 'function') throw invalidArgType('ctor', 'function', ctor);
  if (typeof superCtor !== 'function') throw invalidArgType('superCtor', 'function', superCtor);

  Object.defineProperty(ctor, 'super_', {
    value: superCtor,
    configurable: true,
    enumerable: false,
    writable: true,
  });
  Object.setPrototypeOf(ctor.prototype, superCtor.prototype);
}

function deprecate(fn, message, code) {
  if (typeof fn !== 'function') throw invalidArgType('fn', 'function', fn);

  let warned = false;
  const text = code ? `${message} [${code}]` : String(message);

  function deprecated(...args) {
    if (!warned) {
      warned = true;
      const line = `DeprecationWarning: ${text}`;
      const target = globalThis.process;
      if (target && target.stderr && typeof target.stderr.write === 'function') target.stderr.write(`${line}\n`);
      else if (typeof console !== 'undefined' && typeof console.error === 'function') console.error(line);
    }
    return fn.apply(this, args);
  }

  Object.setPrototypeOf(deprecated, getPrototypeOf(fn));
  return deprecated;
}

// ---------------------------------------------------------------------------
// isDeepStrictEqual
// ---------------------------------------------------------------------------

function isDeepStrictEqual(valueA, valueB) {
  return deepEqual(valueA, valueB, [], []);
}

function deepEqual(a, b, seenA, seenB) {
  if (Object.is(a, b)) return true;
  if (typeof a !== typeof b) return false;
  if (typeof a !== 'object' || a === null || b === null) return false;

  const tag = objectToString.call(a);
  if (tag !== objectToString.call(b)) return false;

  if (tag === '[object Promise]' || tag === '[object WeakMap]' || tag === '[object WeakSet]') return false;
  if (
    tag === '[object Number]' ||
    tag === '[object String]' ||
    tag === '[object Boolean]' ||
    tag === '[object BigInt]' ||
    tag === '[object Symbol]'
  ) {
    return Object.is(a.valueOf(), b.valueOf());
  }

  const index = seenA.indexOf(a);
  if (index !== -1) return seenB[index] === b;

  if (getPrototypeOf(a) !== getPrototypeOf(b)) return false;

  if (tag === '[object Date]') return a.getTime() === b.getTime();
  if (tag === '[object RegExp]') return a.source === b.source && a.flags === b.flags;

  if (tag === '[object ArrayBuffer]') return equalBytes(new Uint8Array(a), new Uint8Array(b));
  if (ArrayBuffer.isView(a)) {
    if (!ArrayBuffer.isView(b) || a.byteLength !== b.byteLength) return false;
    return equalBytes(new Uint8Array(a.buffer, a.byteOffset, a.byteLength), new Uint8Array(b.buffer, b.byteOffset, b.byteLength));
  }

  seenA.push(a);
  seenB.push(b);
  try {
    if (isNativeError(a)) {
      if (!isNativeError(b) || a.name !== b.name || a.message !== b.message) return false;
    } else if (isMap(a)) {
      return equalMaps(a, b, seenA, seenB);
    } else if (isSet(a)) {
      return equalSets(a, b, seenA, seenB);
    } else if (Array.isArray(a)) {
      if (!Array.isArray(b) || a.length !== b.length) return false;
      for (let item = 0; item < a.length; item++) {
        if (!deepEqual(a[item], b[item], seenA, seenB)) return false;
      }
      return true;
    }

    const keysA = enumerableKeys(a);
    const keysB = enumerableKeys(b);
    if (keysA.length !== keysB.length) return false;
    for (const key of keysA) {
      if (!hasOwnProperty.call(b, key)) return false;
      if (!deepEqual(a[key], b[key], seenA, seenB)) return false;
    }
    return true;
  } finally {
    seenA.pop();
    seenB.pop();
  }
}

function equalMaps(a, b, seenA, seenB) {
  if (!isMap(b) || a.size !== b.size) return false;
  const entries = [];
  for (const entry of b) entries.push(entry);
  const used = new Array(entries.length).fill(false);

  for (const entry of a) {
    let found = false;
    for (let index = 0; index < entries.length; index++) {
      if (used[index]) continue;
      if (deepEqual(entry[0], entries[index][0], seenA, seenB) && deepEqual(entry[1], entries[index][1], seenA, seenB)) {
        used[index] = true;
        found = true;
        break;
      }
    }
    if (!found) return false;
  }
  return true;
}

function equalSets(a, b, seenA, seenB) {
  if (!isSet(b) || a.size !== b.size) return false;
  const entries = [];
  for (const entry of b) entries.push(entry);
  const used = new Array(entries.length).fill(false);

  for (const value of a) {
    let found = false;
    for (let index = 0; index < entries.length; index++) {
      if (used[index]) continue;
      if (deepEqual(value, entries[index], seenA, seenB)) {
        used[index] = true;
        found = true;
        break;
      }
    }
    if (!found) return false;
  }
  return true;
}

function equalBytes(a, b) {
  if (a.length !== b.length) return false;
  for (let index = 0; index < a.length; index++) {
    if (a[index] !== b[index]) return false;
  }
  return true;
}

function enumerableKeys(value) {
  const keys = Object.keys(value);
  for (const symbol of Object.getOwnPropertySymbols(value)) {
    const descriptor = Object.getOwnPropertyDescriptor(value, symbol);
    if (descriptor && descriptor.enumerable) keys.push(symbol);
  }
  return keys;
}

export {
  format,
  inspect,
  types,
  promisify,
  callbackify,
  inherits,
  deprecate,
  isDeepStrictEqual,
  TextEncoder,
  TextDecoder,
};
export default {
  format,
  inspect,
  types,
  promisify,
  callbackify,
  inherits,
  deprecate,
  isDeepStrictEqual,
  TextEncoder,
  TextDecoder,
};
