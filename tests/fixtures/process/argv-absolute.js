// Derived from test/parallel/test-process-argv-0.js (nodejs/node).
// The harness passes the resolved absolute fixture path as argv[1].
import process from 'node:process';

const script = process.argv[1];
console.log(`absolute=${script.startsWith('/')}`);
console.log(`file=${script.endsWith('argv-absolute.js')}`);
console.log(`tail=${process.argv.slice(2).join(',')}`);
