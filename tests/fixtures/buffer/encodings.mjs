// Derived from test/parallel/test-buffer-ascii.js, test-buffer-bytelength.js,
// test-buffer-hex.js, test-buffer-base64.js, test-buffer-utf16le.js,
// test-buffer-invalid-utf8.js (nodejs/node).
import { Buffer } from 'node:buffer';

const hello = Buffer.from('hello world');
console.log(`hex=${hello.toString('hex')}`);
console.log(`base64=${hello.toString('base64')}`);
console.log(`base64url=${hello.toString('base64url')}`);
console.log(`utf8=${hello.toString('utf8')}`);
console.log(`upper=${hello.toString('UTF-8')}`);

console.log(`hex-in=${Buffer.from('68656c6c6f', 'hex').toString()}`);
console.log(`base64-in=${Buffer.from('aGVsbG8gd29ybGQ=', 'base64').toString()}`);
console.log(`base64-nopad=${Buffer.from('aGVsbG8gd29ybGQ', 'base64').toString()}`);
console.log(`base64url-in=${Buffer.from('aGVsbG8gd29ybGQ', 'base64url').toString()}`);
console.log(`hex-short=${Buffer.from('abc', 'hex').length}`);
console.log(`hex-bad=${Buffer.from('zz', 'hex').length}`);

console.log(`latin1=${Buffer.from([0xe9]).toString('latin1') === '\u00e9'}`);
console.log(`binary=${Buffer.from([0xe9]).toString('binary') === '\u00e9'}`);
console.log(`latin1-encode=${Buffer.from('\u00e9', 'latin1').toString('hex')}`);
console.log(`ascii-encode=${Buffer.from('\u00e9', 'ascii').toString('hex')}`);
console.log(`ascii-decode=${Buffer.from([0xe9]).toString('ascii')}`);
console.log(`latin1-hi=${Buffer.from([0x80]).toString('latin1') === '\u0080'}`);

console.log(`utf16le-encode=${Buffer.from('abc', 'utf16le').toString('hex')}`);
console.log(`utf16le-decode=${Buffer.from([0xac, 0x20]).toString('utf16le') === '\u20ac'}`);
console.log(`utf16le-euro=${Buffer.from('\u20ac', 'ucs2').toString('hex')}`);
console.log(`utf16le-odd=${Buffer.from([0x61, 0x00, 0x62]).toString('utf16le')}`);

console.log(`replacement=${Buffer.from([0xff, 0x41]).toString('utf8') === '\ufffdA'}`);
console.log(`multibyte=${Buffer.from([0xe2, 0x82, 0xac]).toString('utf8') === '\u20ac'}`);

console.log(`length-utf8=${Buffer.byteLength('\u00e9')}`);
console.log(`length-latin1=${Buffer.byteLength('\u00e9', 'latin1')}`);
console.log(`length-ascii=${Buffer.byteLength('\u00e9', 'ascii')}`);
console.log(`length-utf16le=${Buffer.byteLength('abc', 'utf16le')}`);
console.log(`length-hex=${Buffer.byteLength('abcd', 'hex')}`);
console.log(`length-base64=${Buffer.byteLength('abcd', 'base64')}`);
console.log(`length-buffer=${Buffer.byteLength(hello)}`);

const slice = Buffer.from('abcdef');
console.log(`slice=${slice.toString('utf8', 1, 4)}`);
console.log(`slice-empty=${slice.toString('utf8', 3, 2) === ''}`);
