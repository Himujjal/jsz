// Ported from nodejs/node test/parallel/test-util-format.js,
// test-util-inspect.js, test-util-types.js, test-util-promisify.js,
// test-util-callbackify.js, test-util-inherits.js, and
// test-util-isDeepStrictEqual.js. Output is deterministic and intentionally
// does not require byte-for-byte Node inspect parity.
import util, {
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
} from 'node:util';
import { Buffer } from 'node:buffer';

const out = [];
const log = (line) => out.push(line);

log(`format-specifiers=${format('%s %d %i %f %j', 'str', 42.7, 42.7, '2.5', { a: 1 })}`);
log(`format-percent=${format('%s %%', 'x')}`);
log(`format-extra=${format('hello', 'world', 1, { a: 1 }, ['x'])}`);
log(`format-object=${format({ a: 1 })}`);
log(`format-string-object=${format('%s', { a: [1, 2, 3] })}`);
log(`format-missing=${format('%d %d', 1)}`);
log(`format-control=${format('x%cy', 'color:red')}`);
const circularJson = {};
circularJson.self = circularJson;
log(`format-json-circular=${format('%j', circularJson)}`);
log(`format-bigint=${format('%d %f', 5n, 5n)}`);
log(`format-numbers=${format('%f', '3.9x')}:${format('%i', '3.9x')}`);
log(`format-s-custom=${format('%s', { toString() { return 'custom'; } })}`);

log(`inspect-nested=${inspect({ a: { b: { c: 1 } } })}`);
log(`inspect-depth=${inspect({ a: { b: { c: 1 } } }, { depth: 1 })}`);
log(`inspect-depth-zero=${inspect({ a: { b: { c: 1 } } }, { depth: 0 })}`);
const cyclic = { name: 'cycle' };
cyclic.self = cyclic;
log(`inspect-cycle=${inspect(cyclic)}`);
log(`inspect-map=${inspect(new Map([['a', 1]]))}`);
log(`inspect-set=${inspect(new Set([1, 2]))}`);
log(`inspect-buffer=${inspect(Buffer.from([0x68, 0x69]))}`);
log(`inspect-function=${inspect(function named() {})}`);
class Widget {
  constructor() {
    this.id = 1;
  }
}
log(`inspect-class=${inspect(new Widget())}`);
log(`inspect-date=${inspect(new Date(0))}`);
log(`inspect-regexp=${inspect(/ab/gi)}`);
log(`inspect-error=${inspect(new Error('boom'))}`);
log(`inspect-typed=${inspect(new Uint8Array([1, 2]))}`);
const hidden = Object.defineProperty({ visible: 1 }, 'secret', { value: 2 });
log(`inspect-hidden=${inspect(hidden)}:${inspect(hidden, { showHidden: true })}`);
log(`inspect-sorted=${inspect({ b: 1, a: 2 }, { sorted: true })}`);
log(`inspect-max-array=${inspect([1, 2, 3], { maxArrayLength: 2 })}`);
log(`inspect-holes=${inspect([1, , 3])}`);
log(`inspect-multiline=${JSON.stringify(inspect({ a: 1 }, { compact: false }))}`);
log(`inspect-colors=${inspect(1, { colors: true })}`);
log(`inspect-bigint=${inspect(1n)}`);
log(`inspect-string=${inspect('a\nb')}`);
log(`inspect-null=${inspect(null)}:${inspect(undefined)}`);

const typeFlags = [
  types.isDate(new Date()),
  types.isRegExp(/x/),
  types.isPromise(Promise.resolve()),
  types.isTypedArray(new Uint8Array(1)),
  types.isTypedArray(new DataView(new ArrayBuffer(1))),
  types.isUint8Array(Buffer.from([1])),
  types.isArrayBuffer(new ArrayBuffer(1)),
  types.isMap(new Map()),
  types.isSet(new Set()),
  types.isNativeError(new Error()),
  types.isNativeError({}),
  types.isAsyncFunction(async () => 1),
];
log(`types=${typeFlags.join(',')}`);

function add(a, b, callback) {
  setTimeout(() => callback(null, a + b), 1);
}

function fail(callback) {
  callback(new Error('nope'));
}

function multiple(callback) {
  callback(null, 'a', 'b');
}

const plusOne = callbackify(async (value) => value + 1);

const rejecter = callbackify(async () => {
  throw new Error('bad');
});

function Base() {}
Base.prototype.kind = () => 'base';

function Child() {}
inherits(Child, Base);

let deprecateCalls = 0;
const deprecated = deprecate(() => {
  deprecateCalls++;
  return 'result';
}, 'test message', 'TEST001');

const left = { name: 'l' };
left.self = left;
const right = { name: 'l' };
right.self = right;

async function main() {
  log(`promisify=${await promisify(add)(2, 3)}`);
  try {
    await promisify(fail)();
    log('promisify-error=none');
  } catch (error) {
    log(`promisify-error=${error.message}`);
  }
  log(`promisify-multiple=${(await promisify(multiple)()).join('+')}`);

  const customTarget = () => {};
  customTarget[promisify.custom] = async () => 'custom';
  log(`promisify-custom=${await promisify(customTarget)()}:${typeof promisify.custom}`);

  const callbackValue = await new Promise((resolve, reject) => {
    plusOne(1, (error, value) => (error ? reject(error) : resolve(value)));
  });
  log(`callbackify-value=${callbackValue}`);

  const callbackError = await new Promise((resolve) => {
    rejecter((error) => resolve(error.message));
  });
  log(`callbackify-error=${callbackError}`);

  const child = new Child();
  log(`inherits=${child instanceof Base}:${Child.super_ === Base}:${child.kind()}`);

  // deprecate only writes the warning to stderr; assert the call-through.
  log(`deprecate=${deprecated()}:${deprecateCalls}`);

  log(`deep-nan=${isDeepStrictEqual(NaN, NaN)}`);
  log(`deep-negative-zero=${isDeepStrictEqual(0, -0)}`);
  log(`deep-object=${isDeepStrictEqual({ a: 1, b: [2, 3] }, { b: [2, 3], a: 1 })}`);
  log(`deep-mismatch=${isDeepStrictEqual({ a: 1 }, { a: 2 })}`);
  log(`deep-cycle=${isDeepStrictEqual(left, right)}`);
  log(`deep-date=${isDeepStrictEqual(new Date(0), new Date(0))}:${isDeepStrictEqual(new Date(0), new Date(1))}`);
  log(`deep-regexp=${isDeepStrictEqual(/a/g, /a/g)}:${isDeepStrictEqual(/a/g, /a/i)}`);
  log(`deep-map=${isDeepStrictEqual(new Map([['a', 1], ['b', 2]]), new Map([['b', 2], ['a', 1]]))}`);
  log(`deep-set=${isDeepStrictEqual(new Set([1, 2]), new Set([2, 1]))}`);
  log(`deep-typed=${isDeepStrictEqual(new Uint8Array([1, 2]), new Uint8Array([1, 2]))}:${isDeepStrictEqual(new Uint8Array([1]), new Uint8Array([1, 2]))}`);
  log(`deep-buffer=${isDeepStrictEqual(Buffer.from([1]), new Uint8Array([1]))}`);
  log(`deep-error=${isDeepStrictEqual(new Error('x'), new Error('x'))}:${isDeepStrictEqual(new Error('x'), new Error('y'))}`);

  log(`encoding=${Array.from(new TextEncoder().encode('\u20ac')).join(',')}:${new TextDecoder().decode(new Uint8Array([0xe2, 0x82, 0xac]))}`);

  log(`default-export=${typeof util.format}:${typeof util.inspect}:${util.TextEncoder === TextEncoder}:${util.TextDecoder === TextDecoder}`);
  log(`default-surface=${typeof util.promisify}:${typeof util.callbackify}:${typeof util.inherits}:${typeof util.deprecate}:${typeof util.isDeepStrictEqual}:${typeof util.types.isDate}`);

  globalThis.__result = out.join('\n') + '\n';
}

main();
