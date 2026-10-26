// Derived from test/parallel/test-process-uptime.js (nodejs/node).
import process from 'node:process';

const value = process.uptime();
console.log(`type=${typeof value}`);
console.log(`positive=${value > 0}`);
console.log(`bounded=${value < 3600}`);
