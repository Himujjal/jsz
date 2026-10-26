// Derived from test/parallel/test-process-env.js and
// test-process-env-delete.js (nodejs/node).
// The harness provides JSZ_TEST_ENV=inherited.
import process from 'node:process';

console.log(`inherit=${process.env.JSZ_TEST_ENV}`);

process.env.JSZ_WRITE = 'one';
console.log(`set=${process.env.JSZ_WRITE}`);

process.env.JSZ_WRITE = 'two';
console.log(`overwrite=${process.env.JSZ_WRITE}`);

process.env.JSZ_WRITE = undefined;
console.log(`undefined=${process.env.JSZ_WRITE}`);

process.env.JSZ_WRITE = 'three';
delete process.env.JSZ_WRITE;
console.log(`deleted=${process.env.JSZ_WRITE}`);

console.log(`missing=${process.env.JSZ_ABSENT}`);
