// Node-compatible `node:os`. Host facts come from `node:_process`; the shapes
// and the environment fallbacks live here.

import * as native from 'node:_process';

export const EOL = '\n';
export const devNull = '/dev/null';

export function platform() {
  return native.osPlatform();
}

export function arch() {
  return native.osArch();
}

export function type() {
  return native.osType();
}

export function release() {
  return native.osRelease();
}

export function version() {
  return native.osVersion();
}

export function machine() {
  return native.osMachine();
}

export function hostname() {
  return native.osHostname();
}

export function homedir() {
  // Node prefers $HOME and falls back to the password database; jsz has no
  // entry lookup, so an empty environment falls back to the root directory.
  return native.envGet('HOME') || native.envGet('USERPROFILE') || '/';
}

export function tmpdir() {
  const candidate = native.envGet('TMPDIR') || native.envGet('TEMP') || native.envGet('TMP') || '/tmp';
  const trimmed = candidate.replace(/\/+$/, '');
  return trimmed.length > 0 ? trimmed : '/';
}

export function cpus() {
  const count = native.osCpuCount();
  const list = new Array(count);
  for (let index = 0; index < count; index += 1) {
    list[index] = {
      model: 'unknown',
      speed: 0,
      times: { user: 0, nice: 0, sys: 0, idle: 0, irq: 0 },
    };
  }
  return list;
}

export function availableParallelism() {
  return native.osCpuCount();
}

export function uptime() {
  return native.osUptime();
}

export function loadavg() {
  return native.osLoadavg();
}

export function totalmem() {
  return native.osTotalmem();
}

export function userInfo(options) {
  const home = homedir();
  const username = native.envGet('USER') || native.envGet('LOGNAME') || native.envGet('USERNAME') || '';
  const shell = native.envGet('SHELL') || null;
  void options;
  return {
    uid: native.osUid(),
    gid: native.osGid(),
    username,
    homedir: home,
    shell,
  };
}

const os = {
  EOL,
  devNull,
  platform,
  arch,
  type,
  release,
  version,
  machine,
  hostname,
  homedir,
  tmpdir,
  cpus,
  availableParallelism,
  uptime,
  loadavg,
  totalmem,
  userInfo,
};

export default os;
