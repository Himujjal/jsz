// Derived from test/parallel/test-buffer-isbuffer.js,
// test-buffer-constants.js (nodejs/node).
import { Buffer, INSPECT_MAX_BYTES, kMaxLength, constants } from 'node:buffer';

console.log(`is-buffer=${Buffer.isBuffer(Buffer.from('x'))}:${Buffer.isBuffer(new Uint8Array(1))}:${Buffer.isBuffer('x')}`);
console.log(`is-encoding=${Buffer.isEncoding('utf8')}:${Buffer.isEncoding('hex')}:${Buffer.isEncoding('lol')}`);
console.log(`pool=${typeof Buffer.poolSize}:${Buffer.poolSize > 0}`);
console.log(`inspect-max=${INSPECT_MAX_BYTES}`);
console.log(`kmax=${kMaxLength > 0}:${kMaxLength === constants.MAX_LENGTH}`);
console.log(`constants=${constants.MAX_LENGTH > 0}:${constants.MAX_STRING_LENGTH > 0}`);
console.log(`filled=${Buffer.isBuffer(Buffer.alloc(1))}:${Buffer.isBuffer(Buffer.concat([Buffer.alloc(1)]))}`);
