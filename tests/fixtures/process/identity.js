// Derived from test/parallel/test-process-default.js,
// test-process-ppid.js, test-process-versions.js and test-process-execpath.js
// (nodejs/node), reduced to the surface jsz implements.
import process, * as module from 'node:process';

const platforms = ['darwin', 'linux', 'win32', 'freebsd', 'openbsd', 'netbsd', 'aix', 'sunos', 'android'];
const arches = ['x64', 'arm64', 'ia32', 'arm', 'riscv64', 'ppc64', 's390x', 'loong64'];
const versions = ['jsz', 'zig', 'quickjs', 'zio'];

console.log(`pid=${Number.isInteger(process.pid) && process.pid > 0}`);
console.log(`ppid=${Number.isInteger(process.ppid) && process.ppid >= 0}`);
console.log(`platform=${platforms.includes(process.platform)}`);
console.log(`arch=${arches.includes(process.arch)}`);
console.log(`version=${/^v\d+\.\d+\.\d+/.test(process.version)}`);
console.log(`versions=${versions.every((key) => typeof process.versions[key] === 'string')}`);
console.log(`global=${globalThis.process === process}`);
console.log(`default=${module.default === process}`);
