// Derived from test/parallel/test-process-chdir-errormessage.js (nodejs/node).
import process from 'node:process';

try {
  process.chdir('does-not-exist');
  console.log('threw=false');
} catch (error) {
  console.log('threw=true');
  console.log(`code=${error.code}`);
  console.log(`syscall=${error.syscall}`);
  console.log(`dest=${error.dest}`);
  console.log(`path=${error.path === process.cwd()}`);
  console.log(`message=${/ENOENT: no such file or directory, chdir .+ -> 'does-not-exist'/.test(error.message)}`);
}
