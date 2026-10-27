// Derived from test/parallel/test-whatwg-encoding-*.js (nodejs/node).
import { TextEncoder, TextDecoder } from 'node:util';

const encoder = new TextEncoder();
const decoder = new TextDecoder();

console.log(`encoder-label=${encoder.encoding}`);
console.log(`decoder-label=${decoder.encoding}:${decoder.fatal}:${decoder.ignoreBOM}`);
console.log(`encode=${Array.from(encoder.encode('\u20ac')).map((byte) => byte.toString(16)).join(',')}`);
console.log(`encode-default=${encoder.encode().length}`);
console.log(`decode=${decoder.decode(new Uint8Array([0xe2, 0x82, 0xac])) === '\u20ac'}`);
console.log(`decode-empty=${decoder.decode() === ''}`);
console.log(`decode-arraybuffer=${decoder.decode(new Uint8Array([0x68, 0x69]).buffer)}`);

console.log(`utf16le=${new TextDecoder('utf-16le').decode(new Uint8Array([0xac, 0x20])) === '\u20ac'}`);
console.log(`latin1=${new TextDecoder('latin1').decode(new Uint8Array([0xe9])) === '\u00e9'}`);

const destination = new Uint8Array(2);
const into = encoder.encodeInto('\u20ac', destination);
console.log(`encode-into=${into.read}:${into.written}:${Array.from(destination).map((byte) => byte.toString(16)).join(',')}`);

const tiny = new Uint8Array(1);
console.log(`encode-into-small=${JSON.stringify(encoder.encodeInto('\u20ac', tiny))}:${tiny[0]}`);

console.log(`bom=${decoder.decode(new Uint8Array([0xef, 0xbb, 0xbf, 0x41]))}`);
console.log(`bom-ignore=${new TextDecoder('utf-8', { ignoreBOM: true }).decode(new Uint8Array([0xef, 0xbb, 0xbf, 0x41])).length}`);

try {
  new TextDecoder('utf-8', { fatal: true }).decode(new Uint8Array([0xff]));
  console.log('fatal=no-throw');
} catch (error) {
  console.log(`fatal=${error.name}:${error.code}`);
}

try {
  new TextDecoder('definitely-not-an-encoding');
  console.log('label=no-throw');
} catch (error) {
  console.log(`label=${error.name}:${error.code}`);
}

console.log(`imports=${typeof TextEncoder}:${typeof globalThis.TextDecoder}`);
