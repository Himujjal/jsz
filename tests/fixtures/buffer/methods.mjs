// Derived from test/parallel/test-buffer-slice.js, test-buffer-equals.js,
// test-buffer-compare.js, test-buffer-indexof.js, test-buffer-copy.js,
// test-buffer-write.js, test-buffer-tojson.js (nodejs/node).
import { Buffer } from 'node:buffer';

const parent = Buffer.from('abcdef');
const cut = parent.slice(2, 4);
console.log(`slice=${cut.toString()}:${cut.byteOffset === parent.byteOffset + 2}`);
cut[0] = 0x5a;
console.log(`slice-alias=${parent.toString()}`);

console.log(`equals=${Buffer.from('abc').equals(Buffer.from('abc'))}:${Buffer.from('abc').equals(Buffer.from('abd'))}`);
console.log(`compare=${Buffer.compare(Buffer.from('a'), Buffer.from('b'))}:${Buffer.compare(Buffer.from('b'), Buffer.from('a'))}:${Buffer.compare(Buffer.from('a'), Buffer.from('a'))}`);
console.log(`compare-length=${Buffer.compare(Buffer.from('ab'), Buffer.from('a'))}`);

const haystack = Buffer.from('abcabc');
console.log(`index=${haystack.indexOf('bc')}:${haystack.indexOf('bc', 2)}`);
console.log(`last-index=${haystack.lastIndexOf('bc')}`);
console.log(`includes=${haystack.includes('ca')}:${haystack.includes('zz')}`);
console.log(`index-byte=${haystack.indexOf(0x63)}`);

const target = Buffer.alloc(4);
const copied = Buffer.from('xyz').copy(target, 1);
console.log(`copy=${copied}:${target.toString('hex')}`);

const writable = Buffer.alloc(5, 0x2e);
console.log(`write=${writable.write('abcd')}:${writable.toString()}`);
console.log(`write-limited=${writable.write('zz', 0, 2)}:${writable.toString()}`);

console.log(`json=${JSON.stringify(Buffer.from([1, 2]))}`);
console.log(`keys=${Object.keys(Buffer.from([9])).join(',')}`);
