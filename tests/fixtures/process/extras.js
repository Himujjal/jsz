// Derived from test/parallel/test-process-execpath.js,
// test-process-memoryUsage.js, test-process-umask.js, test-process-title.js
// and test-process-next-tick.js (nodejs/node), reduced to the surface jsz
// implements. Warnings are captured by replacing stderr.write.
import process from 'node:process';

console.log(`exec-argv=${Array.isArray(process.execArgv) && process.execArgv.length === 0 && Object.isFrozen(process.execArgv)}`);
console.log(`exec-path=${typeof process.execPath === 'string' && process.execPath.startsWith('/')}`);

const usage = process.memoryUsage();
const keys = ['rss', 'heapTotal', 'heapUsed', 'external', 'arrayBuffers'];
console.log(`memory=${keys.every((key) => typeof usage[key] === 'number') && usage.rss > 0}`);

const before = process.umask();
let umaskOk = false;
try {
  umaskOk = typeof before === 'number' && process.umask(0o077) === before && process.umask() === 0o077;
} finally {
  process.umask(before);
}
console.log(`umask=${umaskOk}`);
console.log(`umask-restored=${process.umask() === before}`);

process.title = 'jsz-phase3a';
console.log(`title=${process.title}`);

const order = [];
process.nextTick((a, b) => order.push(`${a}${b}`), 'x', 'y');
Promise.resolve().then(() => order.push('promise'));
queueMicrotask(() => console.log(`order=${order.join(',')}`));

const warnings = [];
const original = process.stderr.write;
process.stderr.write = (chunk) => {
  warnings.push(String(chunk));
  return true;
};
try {
  process.emitWarning('careful', 'CustomWarning', 'JSZ001');
  process.emitWarning('bare');
} finally {
  process.stderr.write = original;
}

const normalize = (line) => line.replace(/\(node:\d+\)/, '(node:PID)');
console.log(`warning=${JSON.stringify(normalize(warnings[0]))}`);
console.log(`warning-default=${JSON.stringify(normalize(warnings[1]))}`);

// Read back by `helpers.runFixture`, which asserts through the Zig harness.
globalThis.__result = process.execPath.startsWith('/') ? 'exec-ok' : 'exec-bad';
