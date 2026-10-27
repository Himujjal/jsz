// Derived from test/parallel/test-buffer-read.js, test-buffer-write.js,
// test-buffer-readuint.js, test-buffer-float.js, test-buffer-bigint64.js
// (nodejs/node), reduced to the fixed-width accessors jsz implements.
import { Buffer } from 'node:buffer';

const buffer = Buffer.alloc(8);

console.log(`write-returns=${buffer.writeUInt8(0x41, 0)}:${buffer.toString('ascii', 0, 1)}`);

buffer.writeUInt32BE(0x01020304, 0);
console.log(`u32be=${buffer.readUInt32BE(0).toString(16)}`);
buffer.writeUInt32LE(0x01020304, 0);
console.log(`u32le=${buffer.readUInt32LE(0).toString(16)}`);

buffer.writeInt16LE(-2, 0);
console.log(`i16le=${buffer.readInt16LE(0)}`);
buffer.writeUInt16BE(0xffff, 0);
console.log(`u16be=${buffer.readUInt16BE(0)}`);

buffer.writeBigUInt64BE(0x0102030405060708n, 0);
console.log(`u64=${buffer.readBigUInt64BE(0).toString(16)}`);

buffer.writeFloatLE(1.5, 0);
console.log(`float=${buffer.readFloatLE(0)}`);
buffer.writeDoubleBE(2.25, 0);
console.log(`double=${buffer.readDoubleBE(0)}`);

try {
  buffer.readUInt32BE(6);
  console.log('range=no-throw');
} catch (error) {
  console.log(`range=${error.name}:${error.code}`);
}

try {
  buffer.writeUInt8(1, 9);
  console.log('write-range=no-throw');
} catch (error) {
  console.log(`write-range=${error.name}:${error.code}`);
}
