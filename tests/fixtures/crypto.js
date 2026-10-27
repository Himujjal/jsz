// Node 22 differential vectors for `node:crypto`. The runtime has no Node to
// compare against, so vectors are hardcoded and both named/default imports are
// exercised. Prints a single "ok" via globalThis.__result.
import crypto, {
  createHash,
  createHmac,
  randomBytes,
  randomUUID,
  randomInt,
  getRandomValues,
  timingSafeEqual,
  webcrypto,
  subtle,
  constants,
  getHashes,
} from 'node:crypto';
import { Buffer } from 'node:buffer';

const failures = [];

function check(name, condition, detail = '') {
  if (!condition) failures.push(detail === '' ? name : `${name} (${detail})`);
}

function codeOf(fn) {
  try {
    fn();
    return 'no-throw';
  } catch (error) {
    return `${error.name}:${error.code}`;
  }
}

check('default-namespace', crypto.createHash === createHash && crypto.webcrypto === webcrypto);
check('default-hmac', crypto.createHmac === createHmac && crypto.randomUUID === randomUUID);

// Known SHA vectors for "abc".
check(
  'sha256-abc',
  createHash('sha256').update('abc').digest('hex') ===
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
);
check(
  'md5-abc',
  createHash('md5').update('abc').digest('hex') === '900150983cd24fb0d6963f7d28e17f72',
);
check(
  'sha1-abc',
  createHash('sha1').update('abc').digest('hex') === 'a9993e364706816aba3e25717850c26c9cd0d89d',
);
check(
  'sha384-abc',
  createHash('sha384').update('abc').digest('hex') ===
    'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7',
);
check(
  'sha512-abc',
  createHash('sha512').update('abc').digest('hex') ===
    'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f',
);
check(
  'sha512-256-abc',
  createHash('sha512-256').update('abc').digest('hex') ===
    '53048e2681941ef99b2e29b76b4c7dabe4c2d0c634fc6d46e0e2f13107e7af23',
);
check(
  'sha256-empty',
  createHash('sha256').digest('hex') === 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
);
check('alias-upper', createHash('SHA256').update('abc').digest('hex') === createHash('sha256').update('abc').digest('hex'));
check('alias-dash', createHash('sha-256').update('abc').digest('hex') === createHash('sha256').update('abc').digest('hex'));

// Streaming and encodings.
const streamed = createHash('sha256');
check('update-returns-this', streamed.update('a') === streamed);
check(
  'multi-update',
  streamed.update('b').update(Buffer.from('c')).digest('hex') ===
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
);
check('digest-default-buffer', Buffer.isBuffer(createHash('sha256').update('abc').digest()));
check('digest-empty-buffer', createHash('sha256').digest().length === 32);
check(
  'digest-base64',
  createHash('sha256').update('abc').digest('base64') === 'ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=',
);
check(
  'digest-base64url',
  createHash('sha256').update('abc').digest('base64url') === 'ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0',
);
check('digest-latin1-length', createHash('sha256').update('abc').digest('latin1').length === 32);
check(
  'update-encoding',
  createHash('sha256').update('616263', 'hex').digest('hex') ===
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
);
check(
  'update-arraybuffer',
  createHash('sha256').update(new TextEncoder().encode('abc')).digest('hex') ===
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
);

// copy() must snapshot the current chunks.
const original = createHash('sha256').update('ab');
const cloned = original.copy();
original.update('c');
cloned.update('d');
check('copy-diverges', original.digest('hex') !== cloned.digest('hex'));
check(
  'copy-matches',
  createHash('sha256').update('ab').copy().update('c').digest('hex') ===
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
);

const finalized = createHash('sha256');
finalized.digest();
check('digest-twice', codeOf(() => finalized.digest()) === 'Error:ERR_CRYPTO_HASH_FINALIZED');
check('update-after-digest', codeOf(() => finalized.update('x')) === 'Error:ERR_CRYPTO_HASH_FINALIZED');
check('copy-after-digest', codeOf(() => finalized.copy()) === 'Error:ERR_CRYPTO_HASH_FINALIZED');

// HMAC vectors.
check(
  'hmac-sha256-fox',
  createHmac('sha256', 'key').update('The quick brown fox jumps over the lazy dog').digest('hex') ===
    'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8',
);
check(
  'hmac-md5',
  createHmac('md5', 'key').update('abc').digest('hex') === 'd2fe98063f876b03193afb49b4979591',
);
check(
  'hmac-sha1',
  createHmac('sha1', 'key').update('abc').digest('hex') === '4fd0b215276ef12f2b3e4c8ecac2811498b656fc',
);
check(
  'hmac-sha384',
  createHmac('sha384', 'key').update('abc').digest('hex') ===
    '30ddb9c8f347cffbfb44e519d814f074cf4047a55d6f563324f1c6a33920e5edfb2a34bac60bdc96cd33a95623d7d638',
);
check(
  'hmac-sha512',
  createHmac('sha512', 'key').update('abc').digest('hex') ===
    '3926a207c8c42b0c41792cbd3e1a1aaaf5f7a25704f62dfc939c4987dd7ce060009c5bb1c2447355b3216f10b537e9afa7b64a4e5391b0d631172d07939e087a',
);
check(
  'hmac-sha512-256',
  createHmac('sha512-256', 'key').update('abc').digest('hex') ===
    'f367b7ca80ab2cf85c23e58b73a8fd525a6fa2c66ff105804a2d4cf4df06e129',
);
check(
  'hmac-buffer-key',
  createHmac('sha256', Buffer.from('key')).update('abc').digest('hex') ===
    '9c196e32dc0175f86f4b1cb89289d6619de6bee699e4c378e68309ed97a1a6ab',
);
check(
  'hmac-hex-key',
  createHmac('sha256', '6b6579', { encoding: 'hex' }).update('abc').digest('hex') ===
    '9c196e32dc0175f86f4b1cb89289d6619de6bee699e4c378e68309ed97a1a6ab',
);
// Node 22 HMAC objects have no copy(); jsz provides it, so exercise it only
// when present to keep this fixture runnable under both runtimes.
const hmacWithCopy = createHmac('sha256', 'key').update('ab');
check(
  'hmac-copy',
  typeof hmacWithCopy.copy !== 'function' ||
    hmacWithCopy.copy().update('c').digest('hex') ===
      '9c196e32dc0175f86f4b1cb89289d6619de6bee699e4c378e68309ed97a1a6ab',
);

// randomBytes: sync, zero-length, and callback form.
const bytes = randomBytes(32);
check('randomBytes-buffer', Buffer.isBuffer(bytes) && bytes.length === 32);
check('randomBytes-nonzero', bytes.some((byte) => byte !== 0));
check('randomBytes-zero', randomBytes(0).length === 0);

let randomBytesReturned;
const callbackBytes = await new Promise((resolve, reject) => {
  randomBytesReturned = randomBytes(8, (error, buffer) => (error ? reject(error) : resolve(buffer)));
});
check(
  'randomBytes-callback',
  randomBytesReturned === undefined && Buffer.isBuffer(callbackBytes) && callbackBytes.length === 8,
);

// randomUUID: v4 shape and uniqueness.
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const firstUuid = randomUUID();
const secondUuid = randomUUID();
check('uuid-shape', uuidPattern.test(firstUuid), firstUuid);
check('uuid-distinct', firstUuid !== secondUuid);
check('uuid-length', firstUuid.length === 36);

// randomInt: inclusive min, exclusive max, callback form.
let singleOk = true;
let rangedOk = true;
for (let i = 0; i < 250; i++) {
  const single = randomInt(10);
  if (!Number.isInteger(single) || single < 0 || single >= 10) singleOk = false;
  const ranged = randomInt(10, 20);
  if (!Number.isInteger(ranged) || ranged < 10 || ranged >= 20) rangedOk = false;
}
check('randomInt-single', singleOk);
check('randomInt-range', rangedOk);
check('randomInt-single-value', randomInt(5, 6) === 5);
check('randomInt-excludes-max', randomInt(1, 2) === 1);

const callbackInt = await new Promise((resolve, reject) => {
  randomInt(3, 4, (error, value) => (error ? reject(error) : resolve(value)));
});
check('randomInt-callback', callbackInt === 3);

// getRandomValues fills in place and keeps the view.
const words = new Uint32Array(4);
check('getRandomValues-identity', getRandomValues(words) === words);
check('getRandomValues-length', words.length === 4 && words.byteLength === 16);
check('getRandomValues-nonzero', words.some((word) => word !== 0));
check(
  'webcrypto-shape',
  typeof webcrypto.getRandomValues === 'function' &&
    typeof webcrypto.subtle.digest === 'function' &&
    typeof webcrypto.randomUUID === 'function',
);
const randomBuffer = Buffer.alloc(8);
check('getRandomValues-buffer', getRandomValues(randomBuffer) === randomBuffer && randomBuffer.length === 8);

// timingSafeEqual compares bytes and rejects different lengths.
check('timingSafeEqual-true', timingSafeEqual(Buffer.from('abc'), Buffer.from('abc')));
check('timingSafeEqual-false', timingSafeEqual(Buffer.from('abc'), Buffer.from('abd')) === false);
check(
  'timingSafeEqual-length',
  codeOf(() => timingSafeEqual(Buffer.from('a'), Buffer.from('ab'))) ===
    'RangeError:ERR_CRYPTO_TIMING_SAFE_EQUAL_LENGTH',
);

// Error shapes.
check('unknown-hash', codeOf(() => createHash('nope')) === 'Error:ERR_CRYPTO_HASH_UNKNOWN');
check('unknown-hmac', codeOf(() => createHmac('nope', 'k')) === 'Error:ERR_CRYPTO_HASH_UNKNOWN');
check('hash-non-string', codeOf(() => createHash(5)) === 'TypeError:ERR_INVALID_ARG_TYPE');
check('hmac-bad-key', codeOf(() => createHmac('sha256', 5)) === 'TypeError:ERR_INVALID_ARG_TYPE');
check('randomBytes-negative', codeOf(() => randomBytes(-1)) === 'RangeError:ERR_OUT_OF_RANGE');
check('randomBytes-string', codeOf(() => randomBytes('4')) === 'TypeError:ERR_INVALID_ARG_TYPE');
check('randomInt-equal', codeOf(() => randomInt(3, 3)) === 'RangeError:ERR_OUT_OF_RANGE');
check('randomInt-float', codeOf(() => randomInt(1.5, 3)) === 'TypeError:ERR_INVALID_ARG_TYPE');
check(
  'getRandomValues-float',
  codeOf(() => getRandomValues(new Float64Array(1))) === 'TypeError:ERR_INVALID_ARG_TYPE',
);
check(
  'getRandomValues-quota',
  codeOf(() => getRandomValues(new Uint8Array(65537))) === 'QuotaExceededError:ERR_OUT_OF_RANGE',
);
check(
  'subtle-not-implemented',
  codeOf(() => subtle.digest('SHA-256', new Uint8Array())) === 'Error:ERR_METHOD_NOT_IMPLEMENTED',
);
check('getHashes', getHashes().includes('sha256') && getHashes().includes('sha512-256'));
check('constants-frozen', Object.isFrozen(constants));

globalThis.__result = failures.length === 0 ? 'ok' : failures.join('\n');
