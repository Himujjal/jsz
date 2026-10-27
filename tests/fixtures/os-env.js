// Derived from test/parallel/test-os-homedir-tmpdir.js and
// test-os-userinfo.js (nodejs/node). The harness supplies HOME, TMPDIR, USER
// and SHELL so the environment fallbacks are observable.
import os from 'node:os';

console.log(`home=${os.homedir()}`);
console.log(`tmp=${os.tmpdir()}`);
console.log(`user=${os.userInfo().username}`);
console.log(`shell=${os.userInfo().shell}`);
