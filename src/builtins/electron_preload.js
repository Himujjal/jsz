// Restricted preload facade for `jsz --desktop`.
//
// The preload runs in its own QuickJS context with an audited module
// allowlist. It may only reach the main process through `node:_electron_preload`.

import * as native from 'node:_electron_preload';

const exposed = Object.create(null);
globalThis.__jszExposed = exposed;

function invalidBridgeValue(path) {
  const error = new Error(`The value at "${path}" cannot be exposed across the context bridge`);
  error.code = 'ERR_BRIDGE_UNSUPPORTED_VALUE';
  return error;
}

function describe(value, path, stack) {
  if (typeof value === 'function') return { t: 'fn' };
  if (value === null || typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
    return { t: 'val', v: value };
  }
  if (typeof value === 'undefined') throw invalidBridgeValue(path);
  if (typeof value !== 'object') throw invalidBridgeValue(path);
  if (stack.has(value)) throw invalidBridgeValue(path);
  if (Array.isArray(value)) {
    // Arrays may only carry plain JSON data in v1; functions nested in arrays
    // are rejected rather than silently dropped.
    let copy;
    try {
      copy = JSON.parse(JSON.stringify(value));
    } catch {
      throw invalidBridgeValue(path);
    }
    return { t: 'val', v: copy };
  }

  stack.add(value);
  const node = { t: 'obj', v: Object.create(null) };
  for (const key of Object.keys(value)) {
    node.v[key] = describe(value[key], path.length > 0 ? `${path}.${key}` : key, stack);
  }
  stack.delete(value);
  return node;
}

const contextBridge = {
  exposeInMainWorld(key, api) {
    if (typeof key !== 'string' || key.length === 0) {
      throw new TypeError('The "key" argument must be a non-empty string');
    }
    if (Object.prototype.hasOwnProperty.call(exposed, key)) {
      const error = new Error(`The key "${key}" has already been exposed`);
      error.code = 'ERR_BRIDGE_DUPLICATE_KEY';
      throw error;
    }
    if (api === null || typeof api !== 'object') {
      throw new TypeError('The "api" argument must be an object');
    }

    const descriptor = describe(api, key, new Set());
    native.registerExposed(key, JSON.stringify(descriptor));
    exposed[key] = api;
  },
};

const ipcRenderer = {
  async invoke(channel, ...args) {
    if (typeof channel !== 'string' || channel.length === 0) {
      throw new TypeError('The "channel" argument must be a non-empty string');
    }
    const json = await native.invoke(channel, JSON.stringify(args));
    return JSON.parse(json);
  },

  send(channel, ...args) {
    if (typeof channel !== 'string' || channel.length === 0) {
      throw new TypeError('The "channel" argument must be a non-empty string');
    }
    native.send(channel, JSON.stringify(args));
  },

  on() {
    // Event delivery is exposed to the page as `jsz-ipc` CustomEvents; the
    // preload-side listener surface is retained for shape compatibility.
    return this;
  },

  removeListener() {
    return this;
  },
};

globalThis.__jszCallExposedPayload = async (payloadJson) => {
  const payload = JSON.parse(payloadJson);
  let target = exposed[payload.key];
  for (const part of payload.path) target = target[part];
  if (typeof target !== 'function') {
    const error = new Error(`The exposed value "${payload.key}.${payload.path.join('.')}" is not callable`);
    error.code = 'ERR_BRIDGE_UNSUPPORTED_VALUE';
    throw error;
  }
  const result = await target(...(payload.args || []));
  return JSON.stringify(result === undefined ? null : result);
};

globalThis.__jszTrack = (promise, resolve, reject) => Promise.resolve(promise).then(resolve, reject);

export { contextBridge, ipcRenderer };
