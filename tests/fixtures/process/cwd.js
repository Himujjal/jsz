// Derived from test/parallel/test-process-chdir.js (nodejs/node).
import process from 'node:process';

const start = process.cwd();
console.log(`absolute=${start.startsWith('/')}`);

process.chdir('tests');
console.log(`moved=${process.cwd() !== start}`);

process.chdir(start);
console.log(`restored=${process.cwd() === start}`);
