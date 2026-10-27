// Node.js 22 `node:crypto` facade. Streaming hash state lives here; the
// `node:_crypto` module only performs one-shot digests and entropy reads.

import * as native from 'node:_crypto';
import { Buffer } from 'node:buffer';

const ALGORITHMS = new Map([
  ['md5', 'md5'],
  ['sha1', 'sha1'],
  ['sha-1', 'sha1'],
  ['sha256', 'sha256'],
  ['sha-256', 'sha256'],
  ['sha384', 'sha384'],
  ['sha-384', 'sha384'],
  ['sha512', 'sha512'],
  ['sha-512', 'sha512'],
  ['sha512-256', 'sha512-256'],
]);

const kAlgorithm = Symbol('algorithm');
const kChunks = Symbol('chunks');
const kDigested = Symbol('digested');
const kKey = Symbol('key');

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

function hashUnknown(algorithm) {
  const error = new Error('Digest method not supported');
  error.code = 'ERR_CRYPTO_HASH_UNKNOWN';
  error.algorithm = algorithm;
  return error;
}

function hashFinalized() {
  const error = new Error('Digest already called');
  error.code = 'ERR_CRYPTO_HASH_FINALIZED';
  return error;
}

function notImplemented(operation) {
  const error = new Error(`The ${operation} method is not implemented`);
  error.code = 'ERR_METHOD_NOT_IMPLEMENTED';
  return error;
}

function quotaExceeded(byteLength) {
  const error = new Error(
    `The ArrayBufferView's byte length (${byteLength}) exceeds the number of bytes of entropy available via this API (65536)`,
  );
  error.name = 'QuotaExceededError';
  error.code = 'ERR_OUT_OF_RANGE';
  return error;
}

function normalizeAlgorithm(algorithm) {
  if (typeof algorithm !== 'string') throw invalidArgType('algorithm', 'string', algorithm);
  const canonical = ALGORITHMS.get(algorithm.toLowerCase());
  if (canonical === undefined) throw hashUnknown(algorithm);
  return canonical;
}

/// Copies any Buffer/TypedArray/DataView/ArrayBuffer into a Buffer; strings
/// use `encoding` (default utf8). Null encodings mean the default, as in Node.
function toBuffer(value, encoding, name) {
  if (typeof value === 'string') {
    const selected = encoding === undefined || encoding === null ? 'utf8' : encoding;
    return Buffer.from(value, selected);
  }
  if (value instanceof ArrayBuffer) return Buffer.from(new Uint8Array(value));
  if (ArrayBuffer.isView(value)) return Buffer.from(value);
  throw invalidArgType(name, 'string, Buffer, TypedArray, or DataView', value);
}

function toByteView(value, name) {
  if (value instanceof Uint8Array) return value;
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  throw invalidArgType(name, 'Buffer, TypedArray, or DataView', value);
}

class HashBase {
  constructor(algorithm) {
    this[kAlgorithm] = normalizeAlgorithm(algorithm);
    this[kChunks] = [];
    this[kDigested] = false;
  }

  update(data, inputEncoding) {
    if (this[kDigested]) throw hashFinalized();
    this[kChunks].push(toBuffer(data, inputEncoding, 'data'));
    return this;
  }

  digest(encoding) {
    if (this[kDigested]) throw hashFinalized();
    this[kDigested] = true;

    const result = this._digest();
    if (encoding === undefined || encoding === null) return result;
    return result.toString(encoding);
  }

  copy() {
    if (this[kDigested]) throw hashFinalized();
    const clone = this._clone();
    clone[kChunks] = this[kChunks].slice();
    return clone;
  }

  _clone() {
    return new Hash(this[kAlgorithm]);
  }

  _digest() {
    throw notImplemented('Hash._digest');
  }
}

class Hash extends HashBase {
  _digest() {
    const bytes = native.hash(this[kAlgorithm], Buffer.concat(this[kChunks]));
    if (bytes === null) throw hashUnknown(this[kAlgorithm]);
    return Buffer.from(bytes);
  }
}

class Hmac extends HashBase {
  constructor(algorithm, key, options) {
    super(algorithm);
    const encoding =
      options === null || options === undefined
        ? undefined
        : typeof options === 'object'
          ? options.encoding
          : options;
    this[kKey] = toBuffer(key, encoding, 'key');
  }

  _clone() {
    return new Hmac(this[kAlgorithm], this[kKey]);
  }

  _digest() {
    const bytes = native.hmac(this[kAlgorithm], this[kKey], Buffer.concat(this[kChunks]));
    if (bytes === null) throw hashUnknown(this[kAlgorithm]);
    return Buffer.from(bytes);
  }
}

function createHash(algorithm) {
  return new Hash(algorithm);
}

function createHmac(algorithm, key, options) {
  return new Hmac(algorithm, key, options);
}

function checkCallback(callback) {
  if (callback !== undefined && typeof callback !== 'function') {
    throw invalidArgType('callback', 'function', callback);
  }
}

function checkSize(size) {
  if (typeof size !== 'number') throw invalidArgType('size', 'number', size);
  if (!Number.isInteger(size) || size < 0 || size > 2 ** 31 - 1) {
    throw outOfRange('size', size, '>= 0 && <= 2147483647');
  }
  return size;
}

function randomBytes(size, callback) {
  checkCallback(callback);
  const length = checkSize(size);
  const buffer = Buffer.from(native.randomBytes(length));
  if (callback === undefined) return buffer;

  queueMicrotask(() => callback(null, buffer));
  return undefined;
}

const MAX_RANDOM_RANGE = 2 ** 48 - 1;

function randomBelow(range) {
  const bits = Math.ceil(Math.log2(range));
  const byteCount = Math.ceil(bits / 8);
  const limit = 2 ** bits;

  for (;;) {
    const bytes = native.randomBytes(byteCount);
    let value = 0;
    for (let i = byteCount - 1; i >= 0; i--) value = value * 256 + bytes[i];
    value %= limit;
    if (value < range) return value;
  }
}

function checkInteger(name, value) {
  if (typeof value !== 'number' || !Number.isSafeInteger(value)) {
    throw invalidArgType(name, 'safe integer', value);
  }
  return value;
}

function randomInt(min, max, callback) {
  if (typeof max === 'function') {
    callback = max;
    max = min;
    min = 0;
  } else if (max === undefined) {
    max = min;
    min = 0;
  }
  checkCallback(callback);

  checkInteger('min', min);
  checkInteger('max', max);

  const range = max - min;
  if (range <= 0) throw outOfRange('max - min', range, '> 0');
  if (range > MAX_RANDOM_RANGE) {
    throw outOfRange('max - min', range, `<= ${MAX_RANDOM_RANGE}`);
  }

  const value = min + randomBelow(range);
  if (callback === undefined) return value;

  queueMicrotask(() => callback(null, value));
  return undefined;
}

function isIntegerView(value) {
  if (!ArrayBuffer.isView(value) || value instanceof DataView) return false;
  return (
    value instanceof Int8Array ||
    value instanceof Uint8Array ||
    value instanceof Uint8ClampedArray ||
    value instanceof Int16Array ||
    value instanceof Uint16Array ||
    value instanceof Int32Array ||
    value instanceof Uint32Array ||
    value instanceof BigInt64Array ||
    value instanceof BigUint64Array
  );
}

function getRandomValues(typedArray) {
  if (!isIntegerView(typedArray)) {
    throw invalidArgType('typedArray', 'an integer-type TypedArray', typedArray);
  }

  const byteLength = typedArray.byteLength;
  if (byteLength > 65536) throw quotaExceeded(byteLength);

  if (byteLength > 0) {
    const bytes = native.randomBytes(byteLength);
    new Uint8Array(typedArray.buffer, typedArray.byteOffset, byteLength).set(bytes);
  }
  return typedArray;
}

function randomUUID() {
  const bytes = Buffer.from(native.randomBytes(16));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

const SUBTLE_METHODS = [
  'encrypt',
  'decrypt',
  'sign',
  'verify',
  'digest',
  'generateKey',
  'deriveKey',
  'deriveBits',
  'importKey',
  'exportKey',
  'wrapKey',
  'unwrapKey',
];

const subtle = {};
for (const method of SUBTLE_METHODS) {
  subtle[method] = () => {
    throw notImplemented(`crypto.subtle.${method}`);
  };
}

const webcrypto = { getRandomValues, randomUUID, subtle };

function timingSafeEqual(buf1, buf2) {
  const left = toByteView(buf1, 'buf1');
  const right = toByteView(buf2, 'buf2');
  if (left.byteLength !== right.byteLength) {
    const error = new RangeError('Input buffers must have the same byte length');
    error.code = 'ERR_CRYPTO_TIMING_SAFE_EQUAL_LENGTH';
    throw error;
  }
  return native.timingSafeEqual(left, right);
}

const CANONICAL_ALGORITHMS = ['md5', 'sha1', 'sha256', 'sha384', 'sha512', 'sha512-256'];

function getHashes() {
  return CANONICAL_ALGORITHMS.slice();
}

const constants = Object.freeze({
  OPENSSL_VERSION_NUMBER: 0,
  RSA_PKCS1_PADDING: 1,
  RSA_NO_PADDING: 3,
  RSA_PKCS1_OAEP_PADDING: 4,
  RSA_PKCS1_PSS_PADDING: 6,
  POINT_CONVERSION_COMPRESSED: 2,
  POINT_CONVERSION_UNCOMPRESSED: 4,
  POINT_CONVERSION_HYBRID: 6,
  SSL_OP_ALL: 0x80000bff,
});

export {
  createHash,
  createHmac,
  randomBytes,
  randomUUID,
  randomInt,
  getRandomValues,
  timingSafeEqual,
  getHashes,
  webcrypto,
  subtle,
  constants,
};

export default {
  createHash,
  createHmac,
  randomBytes,
  randomUUID,
  randomInt,
  getRandomValues,
  timingSafeEqual,
  getHashes,
  webcrypto,
  subtle,
  constants,
};
