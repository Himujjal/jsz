// Derived from test/parallel/test-process-argv-0.js (nodejs/node).
// Invoked by the harness as `jsz <abs argv.js> alpha beta`.
import process from 'node:process';

console.log(`len=${process.argv.length}`);
console.log(`script=${process.argv[1].split('/').pop()}`);
console.log(`tail=${process.argv.slice(2).join(',')}`);
console.log(`exe=${typeof process.argv[0] === 'string' && process.argv[0].length > 0}`);
