// Derived from test/parallel/test-os.js (nodejs/node), reduced to the surface
// jsz implements. Every line is host-independent except the boolean checks.
import os, {
  platform,
  arch,
  type,
  release,
  version,
  machine,
  hostname,
  homedir,
  tmpdir,
  EOL,
  devNull,
  cpus,
  availableParallelism,
  uptime,
  loadavg,
  totalmem,
  userInfo,
} from 'node:os';

console.log(`platform=${platform() === process.platform}`);
console.log(`arch=${arch() === process.arch}`);
console.log(`type=${typeof type() === 'string' && type().length > 0}`);
console.log(`release=${typeof release() === 'string' && release().length > 0}`);
console.log(`version=${typeof version() === 'string' && version().length > 0}`);
console.log(`machine=${typeof machine() === 'string' && machine().length > 0}`);
console.log(`hostname=${typeof hostname() === 'string' && hostname().length > 0}`);
console.log(`homedir=${homedir().startsWith('/')}`);
console.log(`tmpdir=${tmpdir().length > 0 && !tmpdir().endsWith('/')}`);
console.log(`eol=${EOL === '\n'}`);
console.log(`devnull=${devNull === '/dev/null'}`);

const cores = cpus();
const shape = cores[0];
console.log(`cpus=${Array.isArray(cores) && cores.length > 0}`);
console.log(`cpu-shape=${shape.model === 'unknown' && shape.speed === 0 && Object.keys(shape.times).length === 5}`);
console.log(`parallel=${availableParallelism() === cores.length}`);

console.log(`uptime=${typeof uptime() === 'number' && uptime() > 0}`);
const load = loadavg();
console.log(`loadavg=${Array.isArray(load) && load.length === 3 && load.every((value) => typeof value === 'number' && value >= 0)}`);

const info = userInfo();
console.log(`user=${Number.isInteger(info.uid) && Number.isInteger(info.gid) && typeof info.username === 'string' && info.homedir === homedir() && (info.shell === null || typeof info.shell === 'string')}`);
console.log(`totalmem=${typeof totalmem() === 'number' && totalmem() > 0}`);

console.log(`default=${os.platform === platform && os.EOL === EOL && os.cpus === cpus}`);

// Read back by `helpers.runFixture`, which asserts through the Zig harness.
globalThis.__result = cores.length > 0 ? 'cpus-ok' : 'cpus-empty';
