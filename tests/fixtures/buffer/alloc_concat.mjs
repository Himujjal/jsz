// Derived from test/parallel/test-buffer-alloc.js, test-buffer-concat.js,
// test-buffer-fill.js (nodejs/node).
import { Buffer } from 'node:buffer';

console.log(`alloc=${Buffer.alloc(4).toString('hex')}`);
console.log(`alloc-fill=${Buffer.alloc(4, 'ab').toString()}`);
console.log(`alloc-byte=${Buffer.alloc(4, 0x41).toString()}`);
console.log(`alloc-empty=${Buffer.alloc(0).length}`);
console.log(`unsafe-length=${Buffer.allocUnsafe(3).length}`);

const first = Buffer.from('ab');
const second = Buffer.from('cd');
console.log(`concat=${Buffer.concat([first, second]).toString()}`);
console.log(`concat-total=${Buffer.concat([first, second], 3).toString()}:${Buffer.concat([first, second], 3).length}`);
console.log(`concat-longer=${Buffer.concat([first, second], 6).toString('hex')}`);
console.log(`concat-empty=${Buffer.concat([]).length}`);

const filled = Buffer.alloc(6);
console.log(`fill-return=${filled.fill(0x2e) === filled}:${filled.toString()}`);
console.log(`fill-range=${Buffer.alloc(4).fill(1, 1, 3).toString('hex')}`);
