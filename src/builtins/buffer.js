// Node-compatible `node:buffer`. Byte codecs live in `node:_encoding`; this
// module owns the `Buffer` class shape, its argument juggling and its errors.

import * as native from 'node:_encoding';

const ALIASES = new Map([
  ['utf8', 'utf8'],
  ['utf-8', 'utf8'],
  ['unicode-1-1-utf-8', 'utf8'],
  ['utf16le', 'utf16le'],
  ['utf-16le', 'utf16le'],
  ['utf-16', 'utf16le'],
  ['ucs2', 'utf16le'],
  ['ucs-2', 'utf16le'],
  ['latin1', 'latin1'],
  ['binary', 'latin1'],
  ['iso-8859-1', 'latin1'],
  ['ascii', 'ascii'],
  ['hex', 'hex'],
  ['base64', 'base64'],
  ['base64url', 'base64url'],
]);

function canonicalEncoding(encoding) {
  if (typeof encoding !== 'string') return undefined;
  const lower = encoding.toLowerCase();
  const direct = ALIASES.get(lower);
  if (direct !== undefined) return direct;
  return ALIASES.get(lower.replace(/^utf[-_]?/, 'utf'));
}

function normalizeEncoding(encoding) {
  const canonical = canonicalEncoding(encoding);
  if (canonical !== undefined) return canonical;
  const error = new TypeError(`Unknown encoding: ${encoding}`);
  error.code = 'ERR_UNKNOWN_ENCODING';
  throw error;
}

function describe(value) {
  if (value === null) return 'null';
  if (typeof value !== 'object') return `${typeof value} (${String(value)})`;
  const name = value.constructor && value.constructor.name;
  return `an instance of ${name || 'Object'}`;
}

function invalidArgType(name, expected, value) {
  const error = new TypeError(`The "${name}" argument must be of type ${expected}. Received ${describe(value)}`);
  error.code = 'ERR_INVALID_ARG_TYPE';
  return error;
}

function outOfRange(name, value, range) {
  const error = new RangeError(`The value of "${name}" is out of range. It must be ${range}. Received ${value}`);
  error.code = 'ERR_OUT_OF_RANGE';
  return error;
}

function invalidArgValue(name, value, reason) {
  const error = new TypeError(`The argument '${name}' ${reason}. Received ${value}`);
  error.code = 'ERR_INVALID_ARG_VALUE';
  return error;
}

function invalidSize(name, value) {
  const error = new RangeError(`The argument '${name}' is invalid. Received ${value}`);
  error.code = 'ERR_INVALID_ARG_VALUE';
  return error;
}

function checkSize(value, name) {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) {
    throw invalidSize(name, value);
  }
  return value;
}

function encodeString(value, encoding) {
  switch (encoding) {
    case 'utf8':
      return native.utf8Encode(value);
    case 'utf16le':
      return native.utf16leEncode(value);
    case 'latin1':
      return native.latin1Encode(value);
    case 'ascii':
      return native.asciiEncode(value);
    case 'hex':
      return native.hexDecode(value);
    case 'base64':
      return native.base64Decode(value);
    case 'base64url':
      return native.base64urlDecode(value);
    default:
      throw invalidArgValue('encoding', encoding, 'is invalid');
  }
}

function decodeBytes(bytes, encoding) {
  switch (encoding) {
    case 'utf8':
      return native.utf8Decode(bytes);
    case 'utf16le':
      return native.utf16leDecode(bytes);
    case 'latin1':
      return native.latin1Decode(bytes);
    case 'ascii':
      return native.asciiDecode(bytes);
    case 'hex':
      return native.hexEncode(bytes);
    case 'base64':
      return native.base64Encode(bytes);
    case 'base64url':
      return native.base64urlEncode(bytes);
    default:
      throw invalidArgValue('encoding', encoding, 'is invalid');
  }
}

/// Returns a Uint8Array view over any byte-ish value, never a copy.
function asBytes(value, name) {
  if (value instanceof Uint8Array) return value;
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  throw invalidArgType(name, 'Buffer, TypedArray, or DataView', value);
}

function clampIndex(value, fallback, max) {
  if (value === undefined || value === null) return fallback;
  const index = Math.trunc(Number(value));
  if (!Number.isFinite(index)) return fallback;
  return index < 0 ? 0 : index > max ? max : index;
}

function compareBytes(a, b) {
  const length = Math.min(a.length, b.length);
  for (let i = 0; i < length; i++) {
    if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  }
  if (a.length === b.length) return 0;
  return a.length < b.length ? -1 : 1;
}

function searchValue(value, encoding) {
  if (typeof value === 'number') {
    if (!Number.isInteger(value) || value < 0 || value > 255) {
      throw outOfRange('value', value, '>= 0 && <= 255');
    }
    return new Uint8Array([value]);
  }
  if (typeof value === 'string') {
    return encodeString(value, normalizeEncoding(encoding === undefined ? 'utf8' : encoding));
  }
  return asBytes(value, 'value');
}

function searchOffset(value, length, fallback) {
  if (value === undefined || value === null) return fallback;
  const offset = Math.trunc(Number(value));
  if (!Number.isFinite(offset)) return fallback;
  if (offset < 0) return Math.max(length + offset, 0);
  return offset;
}

function indexBytes(haystack, needle, from) {
  if (needle.length === 0) return Math.min(from, haystack.length);
  const limit = haystack.length - needle.length;
  for (let i = from; i <= limit; i++) {
    let match = true;
    for (let j = 0; j < needle.length; j++) {
      if (haystack[i + j] !== needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}

function lastIndexBytes(haystack, needle, from) {
  if (needle.length === 0) return Math.min(from, haystack.length);
  for (let i = Math.min(from, haystack.length - needle.length); i >= 0; i--) {
    let match = true;
    for (let j = 0; j < needle.length; j++) {
      if (haystack[i + j] !== needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}

function fillBytes(buffer, value, start, stop, encoding) {
  if (start >= stop) return;
  if (typeof value === 'number') {
    const byte = value & 0xff;
    for (let i = start; i < stop; i++) buffer[i] = byte;
    return;
  }
  const bytes = typeof value === 'string' ? encodeString(value, normalizeEncoding(encoding)) : asBytes(value, 'value');
  if (bytes.length === 0) {
    for (let i = start; i < stop; i++) buffer[i] = 0;
    return;
  }
  for (let i = start, j = 0; i < stop; i++, j++) {
    if (j === bytes.length) j = 0;
    buffer[i] = bytes[j];
  }
}

function dataViewOf(buffer) {
  return new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
}

function checkedOffset(view, offset, size) {
  const index = Number(offset === undefined ? 0 : offset);
  if (!Number.isInteger(index) || index < 0 || index + size > view.byteLength) {
    throw outOfRange('offset', offset, `>= 0 && <= ${view.byteLength - size}`);
  }
  return index;
}

function defineReader(name, method, size, littleEndian) {
  Object.defineProperty(Buffer.prototype, name, {
    configurable: true,
    writable: true,
    value: function read(offset) {
      const view = dataViewOf(this);
      const index = checkedOffset(view, offset, size);
      return littleEndian === undefined ? view[method](index) : view[method](index, littleEndian);
    },
  });
}

function defineWriter(name, method, size, littleEndian) {
  Object.defineProperty(Buffer.prototype, name, {
    configurable: true,
    writable: true,
    value: function write(value, offset) {
      const view = dataViewOf(this);
      const index = checkedOffset(view, offset, size);
      if (littleEndian === undefined) view[method](index, value);
      else view[method](index, value, littleEndian);
      return index + size;
    },
  });
}

let bufferPoolSize = 65536;

class Buffer extends Uint8Array {
  constructor(...args) {
    super(...args);
  }

  static from(value, encodingOrOffset, length) {
    if (typeof value === 'string') {
      const encoding = encodingOrOffset === undefined ? 'utf8' : encodingOrOffset;
      return new Buffer(encodeString(value, normalizeEncoding(encoding)));
    }
    if (value instanceof ArrayBuffer) {
      const offset = encodingOrOffset === undefined ? 0 : checkSize(encodingOrOffset, 'byteOffset');
      const size = length === undefined ? value.byteLength - offset : checkSize(length, 'length');
      return new Buffer(value, offset, size);
    }
    if (ArrayBuffer.isView(value)) {
      const source = new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
      const buffer = new Buffer(source.length);
      buffer.set(source);
      return buffer;
    }
    if (Array.isArray(value)) {
      const buffer = new Buffer(value.length);
      for (let i = 0; i < value.length; i++) buffer[i] = value[i] & 0xff;
      return buffer;
    }
    const error = new TypeError(
      'The first argument must be of type string or an instance of Buffer, ArrayBuffer, or Array or an Array-like Object. ' +
        `Received ${describe(value)}`,
    );
    error.code = 'ERR_INVALID_ARG_TYPE';
    throw error;
  }

  static alloc(size, fill, encoding) {
    const buffer = new Buffer(checkSize(size, 'size'));
    if (fill !== undefined && fill !== 0) buffer.fill(fill, 0, buffer.length, encoding);
    return buffer;
  }

  static allocUnsafe(size) {
    // No pooling: jsz never hands out uninitialised memory.
    return new Buffer(checkSize(size, 'size'));
  }

  static concat(list, totalLength) {
    if (list === undefined || list === null) throw invalidArgType('list', 'Array', list);
    const sources = Array.from(list);
    let length = 0;
    if (totalLength === undefined) {
      for (const item of sources) length += asBytes(item, 'list').length;
    } else {
      length = checkSize(totalLength, 'totalLength');
    }

    const buffer = new Buffer(length);
    let offset = 0;
    for (const item of sources) {
      if (offset >= length) break;
      const bytes = asBytes(item, 'list');
      const count = Math.min(bytes.length, length - offset);
      buffer.set(bytes.subarray(0, count), offset);
      offset += count;
    }
    return buffer;
  }

  static isBuffer(value) {
    return value instanceof Buffer;
  }

  static isEncoding(encoding) {
    return canonicalEncoding(encoding) !== undefined;
  }

  static byteLength(value, encoding) {
    if (typeof value === 'string') {
      const canonical = normalizeEncoding(encoding === undefined ? 'utf8' : encoding);
      return encodeString(value, canonical).length;
    }
    if (value instanceof ArrayBuffer) return value.byteLength;
    if (ArrayBuffer.isView(value)) return value.byteLength;
    throw invalidArgType('string', 'string or an instance of Buffer or ArrayBuffer', value);
  }

  static compare(a, b) {
    return compareBytes(asBytes(a, 'buf1'), asBytes(b, 'buf2'));
  }

  static get poolSize() {
    return bufferPoolSize;
  }

  static set poolSize(value) {
    bufferPoolSize = checkSize(value, 'poolSize');
  }

  toString(encoding, start, end) {
    const canonical = normalizeEncoding(encoding === undefined ? 'utf8' : encoding);
    const length = this.length;
    const begin = clampIndex(start, 0, length);
    const finish = clampIndex(end, length, length);
    // Node returns '' for an inverted or empty range instead of swapping.
    if (begin >= finish) return '';
    return decodeBytes(this.subarray(begin, finish), canonical);
  }

  toJSON() {
    return { type: 'Buffer', data: Array.from(this) };
  }

  slice(start, end) {
    return this.subarray(start, end);
  }

  equals(other) {
    return compareBytes(this, asBytes(other, 'otherBuffer')) === 0;
  }

  compare(target, targetStart, targetEnd, sourceStart, sourceEnd) {
    const other = asBytes(target, 'target');
    if (arguments.length < 2) return compareBytes(this, other);
    const targetFrom = clampIndex(targetStart, 0, other.length);
    const targetTo = clampIndex(targetEnd, other.length, other.length);
    const sourceFrom = clampIndex(sourceStart, 0, this.length);
    const sourceTo = clampIndex(sourceEnd, this.length, this.length);
    return compareBytes(this.subarray(sourceFrom, sourceTo), other.subarray(targetFrom, targetTo));
  }

  indexOf(value, byteOffset, encoding) {
    const needle = searchValue(value, encoding);
    const from = searchOffset(byteOffset, this.length, 0);
    return indexBytes(this, needle, from);
  }

  lastIndexOf(value, byteOffset, encoding) {
    const needle = searchValue(value, encoding);
    const from = searchOffset(byteOffset, this.length, this.length);
    return lastIndexBytes(this, needle, from);
  }

  includes(value, byteOffset, encoding) {
    return this.indexOf(value, byteOffset, encoding) !== -1;
  }

  copy(target, targetStart, sourceStart, sourceEnd) {
    const destination = asBytes(target, 'target');
    const targetFrom = clampIndex(targetStart, 0, destination.length);
    const sourceFrom = clampIndex(sourceStart, 0, this.length);
    const sourceTo = clampIndex(sourceEnd, this.length, this.length);
    const count = Math.min(Math.max(sourceTo - sourceFrom, 0), destination.length - targetFrom);
    if (count <= 0) return 0;
    destination.set(this.subarray(sourceFrom, sourceFrom + count), targetFrom);
    return count;
  }

  fill(value, offset, end, encoding) {
    let start = 0;
    let stop = this.length;
    let canonical = 'utf8';

    if (typeof offset === 'string') {
      canonical = typeof end === 'string' ? end : offset;
    } else {
      start = clampIndex(offset, 0, this.length);
      if (typeof end === 'string') canonical = end;
      else stop = clampIndex(end, this.length, this.length);
      if (typeof encoding === 'string') canonical = encoding;
    }

    fillBytes(this, value, start, stop, canonical);
    return this;
  }

  write(string, offset, length, encoding) {
    let start = 0;
    let max = this.length;
    let canonical = 'utf8';

    if (typeof offset === 'string') {
      canonical = offset;
    } else {
      start = clampIndex(offset, 0, this.length);
      max = this.length - start;
      if (typeof length === 'string') canonical = length;
      else if (length !== undefined) max = clampIndex(length, max, max);
      if (typeof encoding === 'string') canonical = encoding;
    }

    const bytes = encodeString(String(string), normalizeEncoding(canonical));
    const count = Math.min(bytes.length, max);
    this.set(bytes.subarray(0, count), start);
    return count;
  }
}

defineReader('readUInt8', 'getUint8', 1);
defineReader('readInt8', 'getInt8', 1);
defineReader('readUInt16LE', 'getUint16', 2, true);
defineReader('readUInt16BE', 'getUint16', 2, false);
defineReader('readInt16LE', 'getInt16', 2, true);
defineReader('readInt16BE', 'getInt16', 2, false);
defineReader('readUInt32LE', 'getUint32', 4, true);
defineReader('readUInt32BE', 'getUint32', 4, false);
defineReader('readInt32LE', 'getInt32', 4, true);
defineReader('readInt32BE', 'getInt32', 4, false);
defineReader('readFloatLE', 'getFloat32', 4, true);
defineReader('readFloatBE', 'getFloat32', 4, false);
defineReader('readDoubleLE', 'getFloat64', 8, true);
defineReader('readDoubleBE', 'getFloat64', 8, false);
defineReader('readBigInt64LE', 'getBigInt64', 8, true);
defineReader('readBigInt64BE', 'getBigInt64', 8, false);
defineReader('readBigUInt64LE', 'getBigUint64', 8, true);
defineReader('readBigUInt64BE', 'getBigUint64', 8, false);

defineWriter('writeUInt8', 'setUint8', 1);
defineWriter('writeInt8', 'setInt8', 1);
defineWriter('writeUInt16LE', 'setUint16', 2, true);
defineWriter('writeUInt16BE', 'setUint16', 2, false);
defineWriter('writeInt16LE', 'setInt16', 2, true);
defineWriter('writeInt16BE', 'setInt16', 2, false);
defineWriter('writeUInt32LE', 'setUint32', 4, true);
defineWriter('writeUInt32BE', 'setUint32', 4, false);
defineWriter('writeInt32LE', 'setInt32', 4, true);
defineWriter('writeInt32BE', 'setInt32', 4, false);
defineWriter('writeFloatLE', 'setFloat32', 4, true);
defineWriter('writeFloatBE', 'setFloat32', 4, false);
defineWriter('writeDoubleLE', 'setFloat64', 8, true);
defineWriter('writeDoubleBE', 'setFloat64', 8, false);
defineWriter('writeBigInt64LE', 'setBigInt64', 8, true);
defineWriter('writeBigInt64BE', 'setBigInt64', 8, false);
defineWriter('writeBigUInt64LE', 'setBigUint64', 8, true);
defineWriter('writeBigUInt64BE', 'setBigUint64', 8, false);

const constants = {
  MAX_LENGTH: 9007199254740991,
  MAX_STRING_LENGTH: 536870888,
};

const INSPECT_MAX_BYTES = 50;
const kMaxLength = constants.MAX_LENGTH;
const SlowBuffer = Buffer;

Buffer.INSPECT_MAX_BYTES = INSPECT_MAX_BYTES;
Buffer.kMaxLength = kMaxLength;
Buffer.constants = constants;
Buffer.SlowBuffer = Buffer;

function invalidCharacter(message) {
  const error = new Error(message);
  error.name = 'InvalidCharacterError';
  error.code = 'ERR_INVALID_CHARACTER';
  return error;
}

function btoa(data) {
  const text = String(data);
  const bytes = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (code > 0xff) {
      throw invalidCharacter('The string to be encoded contains characters outside of the Latin1 range.');
    }
    bytes[i] = code;
  }
  return native.base64Encode(bytes);
}

function atob(data) {
  if (typeof data !== 'string') throw invalidArgType('data', 'string', data);
  return native.latin1Decode(native.base64Decode(data));
}

export { Buffer, SlowBuffer, atob, btoa, INSPECT_MAX_BYTES, kMaxLength, constants };
export default { Buffer, SlowBuffer, atob, btoa, INSPECT_MAX_BYTES, kMaxLength, constants };
