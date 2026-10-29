// Node.js `node:net` subset: TCP servers and sockets.
//
// Native code owns the descriptors and reports every event through one
// module-level `dispatch(id, event, payload)` trampoline. This facade turns
// those plain payloads into EventEmitter events and keeps the JS-side state
// (`connecting`, `destroyed`, backpressure, encodings) in sync.

import * as native from 'node:_net';
import { EventEmitter } from 'node:events';
import { Buffer } from 'node:buffer';

const sockets = new Map();
const servers = new Map();

function invalidArgType(name, expected, value) {
  let received;
  if (value === null) received = 'null';
  else if (typeof value === 'function') received = `function ${value.name || '(anonymous)'}`;
  else if (typeof value === 'object') {
    const type = value.constructor && value.constructor.name;
    received = type ? `an instance of ${type}` : 'an object';
  } else received = `${typeof value} (${String(value)})`;

  const error = new TypeError(`The "${name}" argument must be of type ${expected}. Received ${received}`);
  error.code = 'ERR_INVALID_ARG_TYPE';
  return error;
}

function invalidArgValue(name, value, reason) {
  const error = new TypeError(`The argument '${name}' ${reason}. Received ${String(value)}`);
  error.code = 'ERR_INVALID_ARG_VALUE';
  return error;
}

function normalizePort(value) {
  if (typeof value === 'string' && value.trim() !== '' && /^\d+$/.test(value.trim())) value = Number(value.trim());
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw invalidArgType('port', 'number', value);
  }
  if (!Number.isInteger(value) || value < 0 || value > 65535) {
    const error = new RangeError(`The value of "port" is out of range. It must be >= 0 and <= 65535. Received ${value}`);
    error.code = 'ERR_SOCKET_BAD_PORT';
    throw error;
  }
  return value;
}

function normalizeEncoding(encoding) {
  if (encoding === undefined || encoding === null) return null;
  const name = String(encoding).toLowerCase();
  if (name === 'buffer') return null;
  if (!Buffer.isEncoding(name)) throw invalidArgValue('encoding', encoding, 'is invalid encoding');
  return name;
}

function toChunk(data, encoding) {
  if (typeof data === 'string') {
    return Buffer.from(data, encoding === undefined || encoding === null ? 'utf8' : encoding);
  }
  if (Buffer.isBuffer(data)) return data;
  if (ArrayBuffer.isView(data)) return Buffer.from(data.buffer, data.byteOffset, data.byteLength);
  if (data instanceof ArrayBuffer) return Buffer.from(data);
  throw invalidArgType('chunk', 'string, Buffer, or Uint8Array', data);
}

function socketError(payload) {
  const error = new Error(payload.message);
  error.code = payload.code;
  error.errno = payload.errno;
  error.syscall = payload.syscall;
  return error;
}

/// Listener errors must not unwind into the native dispatch frame; report them
/// the way an asynchronous throw would.
function emitSafely(emitter, name, ...args) {
  try {
    emitter.emit(name, ...args);
  } catch (error) {
    queueMicrotask(() => {
      throw error;
    });
  }
}

function applyAddress(target, payload) {
  if (payload.remoteAddress !== undefined) {
    target.remoteAddress = payload.remoteAddress;
    target.remotePort = payload.remotePort;
  }
  if (payload.localAddress !== undefined) {
    target.localAddress = payload.localAddress;
    target.localPort = payload.localPort;
  }
}

class Socket extends EventEmitter {
  constructor(options) {
    super();
    this._id = -1;
    this._encoding = null;
    this._paused = false;
    this._buffered = [];
    this._ended = false;
    this._needDrain = false;
    this._connectCallbacks = [];

    this.connecting = false;
    this.destroyed = false;
    this.readable = true;
    this.writable = true;
    // Plain TCP only; `node:tls` would own the true case.
    this.encrypted = false;
    this.pending = false;
    this.remoteAddress = undefined;
    this.remotePort = undefined;
    this.localAddress = undefined;
    this.localPort = undefined;
    this.bytesRead = 0;
    this.bytesWritten = 0;

    if (options !== undefined && options !== null) this._options = options;
  }

  _dispatch(event, payload) {
    switch (event) {
      case 'connect': {
        this.connecting = false;
        applyAddress(this, payload);
        for (const callback of this._connectCallbacks) {
          if (typeof callback === 'function') queueMicrotask(callback);
        }
        this._connectCallbacks = [];
        emitSafely(this, 'connect');
        return;
      }
      case 'data': {
        const bytes = Buffer.from(payload);
        this.bytesRead += bytes.length;
        const chunk = this._encoding === null ? bytes : bytes.toString(this._encoding);
        if (this._paused) {
          this._buffered.push(chunk);
          return;
        }
        emitSafely(this, 'data', chunk);
        return;
      }
      case 'end': {
        if (this._paused) {
          this._ended = true;
          return;
        }
        this.readable = false;
        emitSafely(this, 'end');
        return;
      }
      case 'drain': {
        if (this._needDrain) {
          this._needDrain = false;
          emitSafely(this, 'drain');
        }
        return;
      }
      case 'error': {
        emitSafely(this, 'error', socketError(payload));
        return;
      }
      case 'close': {
        this.destroyed = true;
        this.connecting = false;
        this.readable = false;
        this.writable = false;
        sockets.delete(this._id);
        this._id = -1;
        emitSafely(this, 'close', payload.hadError === true);
        return;
      }
      default:
        return;
    }
  }

  _bind(id) {
    this._id = id;
    sockets.set(id, this);
    native.socketSetRef(id, this._ref !== false);
    return this;
  }

  connect(...args) {
    const options = normalizeConnectArgs(args);
    this.connecting = true;
    if (typeof options.callback === 'function') this._connectCallbacks.push(options.callback);

    const result = native.connect(options.host, options.port, dispatch);
    if (result.error !== undefined && result.error !== null) {
      const error = socketError(result.error);
      this.connecting = false;
      this.destroyed = true;
      queueMicrotask(() => emitSafely(this, 'error', error));
      return this;
    }

    this._bind(result.id);
    return this;
  }

  write(data, encoding, callback) {
    if (typeof encoding === 'function') {
      callback = encoding;
      encoding = undefined;
    }

    if (this.destroyed || !this.writable) {
      const error = new Error('write after end');
      error.code = 'ERR_STREAM_WRITE_AFTER_END';
      queueMicrotask(() => emitSafely(this, 'error', error));
      return false;
    }

    const chunk = toChunk(data, encoding);
    const status = this._id < 0 ? 2 : native.write(this._id, chunk);
    if (status !== 2) this.bytesWritten += chunk.length;
    if (typeof callback === 'function') queueMicrotask(callback);

    if (status === 2) {
      this.writable = false;
      return false;
    }
    if (status === 1) {
      this._needDrain = true;
      return false;
    }
    return true;
  }

  end(data, encoding, callback) {
    if (typeof data === 'function') {
      callback = data;
      data = undefined;
      encoding = undefined;
    } else if (typeof encoding === 'function') {
      callback = encoding;
      encoding = undefined;
    }

    if (data !== undefined && data !== null) this.write(data, encoding);

    if (this.writable) {
      this.writable = false;
      if (this._id >= 0) native.end(this._id);
    }
    if (typeof callback === 'function') queueMicrotask(callback);
    return this;
  }

  destroy(error) {
    if (this.destroyed) return this;
    this.destroyed = true;

    if (this._id >= 0) native.destroy(this._id);
    if (error !== undefined && error !== null) {
      queueMicrotask(() => emitSafely(this, 'error', error));
    }
    return this;
  }

  setEncoding(encoding) {
    this._encoding = normalizeEncoding(encoding);
    return this;
  }

  setNoDelay(enabled) {
    // zio enables TCP_NODELAY on every accepted/connected stream.
    this._noDelay = enabled === undefined ? true : enabled !== false;
    return this;
  }

  setKeepAlive(enabled, initialDelay) {
    this._keepAlive = enabled !== false;
    this._keepAliveDelay = initialDelay;
    return this;
  }

  address() {
    if (this._id < 0) return null;
    const result = native.address(this._id);
    if (result.error !== undefined && result.error !== null) return null;
    return { address: result.address, family: result.family, port: result.port };
  }

  ref() {
    this._ref = true;
    if (this._id >= 0) native.socketSetRef(this._id, true);
    return this;
  }

  unref() {
    this._ref = false;
    if (this._id >= 0) native.socketSetRef(this._id, false);
    return this;
  }

  pause() {
    this._paused = true;
    return this;
  }

  resume() {
    if (!this._paused) return this;
    this._paused = false;

    const pending = this._buffered;
    this._buffered = [];
    for (const chunk of pending) emitSafely(this, 'data', chunk);

    if (this._ended) {
      this._ended = false;
      this.readable = false;
      emitSafely(this, 'end');
    }
    return this;
  }

  set timeout(ms) {
    this._timeout = ms;
  }

  get timeout() {
    return this._timeout === undefined ? 0 : this._timeout;
  }

  setTimeout(ms, callback) {
    this._timeout = ms;
    if (typeof callback === 'function') this.once('timeout', callback);
    return this;
  }
}

function normalizeConnectArgs(args) {
  const first = args[0];
  let host = 'localhost';
  let port = 0;
  let callback;

  if (first !== null && typeof first === 'object') {
    port = normalizePort(first.port);
    if (typeof first.host === 'string' && first.host.length > 0) host = first.host;
    callback = typeof args[1] === 'function' ? args[1] : first.callback;
  } else {
    port = normalizePort(first);
    if (typeof args[1] === 'string') {
      host = args[1];
      callback = typeof args[2] === 'function' ? args[2] : undefined;
    } else {
      callback = typeof args[1] === 'function' ? args[1] : undefined;
    }
  }

  return { host, port, callback };
}

class Server extends EventEmitter {
  constructor(options, connectionListener) {
    super();
    this._id = -1;
    this.listening = false;
    this.destroyed = false;
    this.maxConnections = undefined;
    this._closeCallbacks = [];
    /// Live sockets accepted by this server; `getConnections` reports the count.
    /// `close()` does not wait for them, unlike Node.
    this._connections = new Set();

    if (typeof options === 'function') {
      connectionListener = options;
      options = undefined;
    } else if (typeof options === 'number') {
      options = { port: options };
    }
    this._options = options === undefined || options === null ? {} : options;
    if (typeof connectionListener === 'function') this.on('connection', connectionListener);
  }

  _dispatch(event, payload) {
    switch (event) {
      case 'connection': {
        const socket = new Socket();
        socket._id = payload.socketId;
        socket.connecting = false;
        socket.remoteAddress = payload.remoteAddress;
        socket.remotePort = payload.remotePort;
        socket.localAddress = payload.localAddress;
        socket.localPort = payload.localPort;
        sockets.set(payload.socketId, socket);
        this._connections.add(socket);
        socket.once('close', () => this._connections.delete(socket));
        emitSafely(this, 'connection', socket);
        return;
      }
      case 'error': {
        emitSafely(this, 'error', socketError(payload));
        return;
      }
      case 'close': {
        this.listening = false;
        servers.delete(this._id);
        this._id = -1;
        emitSafely(this, 'close');
        const callbacks = this._closeCallbacks;
        this._closeCallbacks = [];
        for (const callback of callbacks) queueMicrotask(() => callback());
        return;
      }
      default:
        return;
    }
  }

  listen(...args) {
    if (this.listening) {
      const error = new Error('Listen method has been called more than once without closing.');
      error.code = 'ERR_SERVER_ALREADY_LISTEN';
      throw error;
    }
    const options = normalizeListenArgs(args, this._options);
    if (typeof options.callback === 'function') this.once('listening', options.callback);

    const result = native.listen(options.host, options.port, options.backlog, dispatch);
    if (result.error !== undefined && result.error !== null) {
      const error = socketError(result.error);
      this.listening = false;
      this.destroyed = true;
      queueMicrotask(() => emitSafely(this, 'error', error));
      return this;
    }

    this._id = result.id;
    this.listening = true;
    this._connections.clear();
    this.addressValue = { address: result.address, family: result.family, port: result.port };
    servers.set(result.id, this);
    native.serverSetRef(result.id, this._ref !== false);

    queueMicrotask(() => {
      if (this.destroyed) return;
      emitSafely(this, 'listening');
    });
    return this;
  }

  close(callback) {
    if (this._id < 0) {
      // Node reports a close without a live server through the callback.
      if (typeof callback === 'function') {
        const error = new Error('Server is not running.');
        error.code = 'ERR_SERVER_NOT_RUNNING';
        queueMicrotask(() => callback(error));
      }
      return this;
    }

    if (typeof callback === 'function') this._closeCallbacks.push(callback);
    // Unlike Node, `close()` does not wait for accepted sockets to end: the
    // native accept loop stops immediately and emits `close`. Waiting would
    // require tracking accepts that have not reached JS yet, which is racy.
    this.listening = false;
    native.closeServer(this._id);
    return this;
  }

  address() {
    if (this._id < 0) return null;
    const result = native.address(this._id);
    if (result.error !== undefined && result.error !== null) return this.addressValue ?? null;
    return { address: result.address, family: result.family, port: result.port };
  }

  getConnections(callback) {
    if (typeof callback === 'function') queueMicrotask(() => callback(null, this._connections.size));
    return this;
  }

  ref() {
    this._ref = true;
    if (this._id >= 0) native.serverSetRef(this._id, true);
    return this;
  }

  unref() {
    this._ref = false;
    if (this._id >= 0) native.serverSetRef(this._id, false);
    return this;
  }

  [Symbol.asyncIterator]() {
    const queue = [];
    let wake = null;
    let done = false;

    const push = (socket) => {
      queue.push(socket);
      if (wake !== null) {
        const resume = wake;
        wake = null;
        resume();
      }
    };
    const finish = () => {
      done = true;
      if (wake !== null) {
        const resume = wake;
        wake = null;
        resume();
      }
    };

    this.on('connection', push);
    this.on('close', finish);

    return {
      next: async () => {
        while (queue.length === 0 && !done) {
          await new Promise((resolve) => {
            wake = resolve;
          });
        }
        if (queue.length === 0) return { value: undefined, done: true };
        return { value: queue.shift(), done: false };
      },
      return: async () => {
        this.removeListener('connection', push);
        this.removeListener('close', finish);
        return { value: undefined, done: true };
      },
    };
  }
}

function normalizeListenArgs(args, base) {
  const options = { port: 0, host: '0.0.0.0', backlog: 511, callback: undefined };
  if (base !== undefined && base !== null && typeof base === 'object') {
    if (base.port !== undefined) options.port = normalizePort(base.port);
    if (typeof base.host === 'string') options.host = base.host;
    if (typeof base.backlog === 'number') options.backlog = base.backlog;
  }

  const first = args[0];
  if (first !== null && typeof first === 'object') {
    if (first.port !== undefined) options.port = normalizePort(first.port);
    if (typeof first.host === 'string') options.host = first.host;
    if (typeof first.backlog === 'number') options.backlog = first.backlog;
    options.callback = typeof args[1] === 'function' ? args[1] : first.callback;
    return options;
  }

  if (typeof first === 'function') {
    options.callback = first;
    return options;
  }
  if (first !== undefined) options.port = normalizePort(first);
  if (typeof args[1] === 'string') {
    options.host = args[1];
    if (typeof args[2] === 'number') {
      options.backlog = args[2];
      options.callback = typeof args[3] === 'function' ? args[3] : undefined;
    } else {
      options.callback = typeof args[2] === 'function' ? args[2] : undefined;
    }
  } else {
    if (typeof args[1] === 'number') {
      options.backlog = args[1];
      options.callback = typeof args[2] === 'function' ? args[2] : undefined;
    } else {
      options.callback = typeof args[1] === 'function' ? args[1] : undefined;
    }
  }
  return options;
}

function createServer(options, connectionListener) {
  if (typeof options === 'function') {
    return new Server(undefined, options);
  }
  return new Server(options, connectionListener);
}

function connect(...args) {
  const resolved = normalizeConnectArgs(args);
  const socket = new Socket(resolved);
  return socket.connect(resolved.port, resolved.host, resolved.callback);
}

function isIP(value) {
  return isIPv4(value) ? 4 : isIPv6(value) ? 6 : 0;
}

function isIPv4(value) {
  if (typeof value !== 'string') return false;
  const parts = value.split('.');
  if (parts.length !== 4) return false;
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return false;
    if (part.length > 1 && part[0] === '0') return false;
    if (Number(part) > 255) return false;
  }
  return true;
}

function isIPv6(value) {
  if (typeof value !== 'string' || !value.includes(':')) return false;
  if (value.includes(':::')) return false;

  const doubleColon = value.split('::').length - 1;
  if (doubleColon > 1) return false;

  const pieces = value.split(':');
  if (pieces.length > 8) return false;
  if (doubleColon === 0 && pieces.length !== 8) return false;
  if (doubleColon === 1 && pieces.length > 8) return false;

  for (const piece of pieces) {
    if (piece.length === 0) continue;
    if (piece.includes('.')) {
      if (!isIPv4(piece)) return false;
      continue;
    }
    if (!/^[0-9a-fA-F]{1,4}$/.test(piece)) return false;
  }
  return true;
}

/// Single native trampoline shared by every socket and server.
function dispatch(id, event, payload) {
  const socket = sockets.get(id);
  if (socket !== undefined) {
    socket._dispatch(event, payload);
    return;
  }
  const server = servers.get(id);
  if (server !== undefined) {
    server._dispatch(event, payload);
  }
}

export { Socket, Server, createServer, connect, isIP, isIPv4, isIPv6 };
export const createConnection = connect;

export default {
  Socket,
  Server,
  createServer,
  createConnection,
  connect,
  isIP,
  isIPv4,
  isIPv6,
};
