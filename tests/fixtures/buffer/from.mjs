// Derived from test/parallel/test-buffer-arraybuffer.js,
// test-buffer-from.js, test-buffer-backing-arraybuffer.js (nodejs/node).
import { Buffer } from 'node:buffer';

console.log(`string=${Buffer.from('abc').toString()}`);
console.log(`instance=${Buffer.from('abc') instanceof Buffer}:${Buffer.from('abc') instanceof Uint8Array}`);

const array = Buffer.from([1, 2, 255]);
console.log(`array=${array.toString('hex')}:${array.length}`);

const source = new Uint8Array([1, 2, 3]);
const copy = Buffer.from(source);
copy[0] = 9;
console.log(`copy=${source[0] === 1}:${copy[0]}`);

const buffer = new ArrayBuffer(4);
const shared = Buffer.from(buffer);
shared[0] = 7;
console.log(`shared=${new Uint8Array(buffer)[0] === 7}:${shared.length}`);

const windowed = Buffer.from(buffer, 1, 2);
console.log(`window=${windowed.length}:${windowed.byteOffset}`);

console.log(`hex=${Buffer.from('6869', 'hex').toString()}`);
console.log(`default=${Buffer.from('hi').length}`);
console.log(`empty=${Buffer.from('').length}`);
console.log(`proto=${Object.getPrototypeOf(Buffer.from('abc').subarray(1)) === Buffer.prototype}`);
