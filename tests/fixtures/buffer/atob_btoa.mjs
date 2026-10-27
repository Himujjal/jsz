// Derived from test/parallel/test-buffer-btoa-atob.js (nodejs/node).
import { Buffer, atob, btoa } from 'node:buffer';

console.log(`btoa=${btoa('hello')}`);
console.log(`atob=${atob('aGVsbG8=')}`);
console.log(`roundtrip=${atob(btoa('hello world'))}`);
console.log(`empty=${atob('') === ''}`);

const latin1 = String.fromCharCode(0xe9);
console.log(`binary=${atob(btoa(latin1)) === latin1}`);
console.log(`whitespace=${atob('aGVs\nbG8=')}`);

try {
  btoa('\u20ac');
  console.log('invalid=no-throw');
} catch (error) {
  console.log(`invalid=${error.name}`);
}

console.log(`global=${globalThis.btoa === btoa}:${globalThis.atob === atob}`);
console.log(`bytes=${Buffer.from('hello').toString('base64')}`);
