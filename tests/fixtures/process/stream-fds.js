// Node code branches on the stdio descriptor numbers, so they must be present.
import process from 'node:process';

console.log(`stdout=${process.stdout.fd}`);
console.log(`stderr=${process.stderr.fd}`);
console.log(`stdin=${process.stdin === undefined}`);
