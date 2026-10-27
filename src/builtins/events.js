// Node-compatible `node:events`. Listeners are stored per event name in a
// Map; emit snapshots the list so listeners added during an emit wait for the
// next one. Default export is the class, mirroring `require('events')`.

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

function validateEventName(name) {
  if (typeof name !== 'string' && typeof name !== 'symbol') {
    throw invalidArgType('eventName', 'string or symbol', name);
  }
}

function validateListener(listener) {
  if (typeof listener !== 'function') throw invalidArgType('listener', 'function', listener);
}

function unhandledError(value) {
  if (value instanceof Error) return value;
  const text = typeof value === 'string' ? `'${value}'` : String(value);
  const error = new Error(`Unhandled error. (${text})`);
  error.code = 'ERR_UNHANDLED_ERROR';
  error.context = value;
  return error;
}

function onceWrapper(emitter, name, listener) {
  function wrapped(...args) {
    emitter.removeListener(name, wrapped);
    return listener.apply(emitter, args);
  }
  wrapped.listener = listener;
  return wrapped;
}

function unwrap(listener) {
  return listener && typeof listener.listener === 'function' ? listener.listener : listener;
}

class EventEmitter {
  constructor() {
    this._events = new Map();
    this._maxListeners = undefined;
  }

  _addListener(name, listener, prepend) {
    validateEventName(name);
    validateListener(listener);

    if (this._events.has('newListener')) {
      this.emit('newListener', name, unwrap(listener));
    }

    const list = this._events.get(name);
    if (list === undefined) this._events.set(name, [listener]);
    else if (prepend) list.unshift(listener);
    else list.push(listener);
  }

  on(name, listener) {
    this._addListener(name, listener, false);
    return this;
  }

  addListener(name, listener) {
    return this.on(name, listener);
  }

  prependListener(name, listener) {
    this._addListener(name, listener, true);
    return this;
  }

  once(name, listener) {
    validateEventName(name);
    validateListener(listener);
    this._addListener(name, onceWrapper(this, name, listener), false);
    return this;
  }

  prependOnceListener(name, listener) {
    validateEventName(name);
    validateListener(listener);
    this._addListener(name, onceWrapper(this, name, listener), true);
    return this;
  }

  off(name, listener) {
    return this.removeListener(name, listener);
  }

  removeListener(name, listener) {
    validateEventName(name);
    validateListener(listener);

    const list = this._events.get(name);
    if (list === undefined) return this;

    for (let index = list.length - 1; index >= 0; index--) {
      const entry = list[index];
      if (entry !== listener && entry.listener !== listener) continue;

      list.splice(index, 1);
      if (list.length === 0) this._events.delete(name);
      if (this._events.has('removeListener')) this.emit('removeListener', name, unwrap(entry));
      return this;
    }
    return this;
  }

  removeAllListeners(name) {
    if (name !== undefined) {
      validateEventName(name);
      const list = this._events.get(name);
      if (list === undefined) return this;

      if (name !== 'removeListener' && this._events.has('removeListener')) {
        for (const entry of list.slice()) this.emit('removeListener', name, unwrap(entry));
      }
      this._events.delete(name);
      return this;
    }

    for (const key of Array.from(this._events.keys())) {
      if (key !== 'removeListener') this.removeAllListeners(key);
    }
    this.removeAllListeners('removeListener');
    return this;
  }

  emit(name, ...args) {
    const list = this._events.get(name);
    if (list === undefined || list.length === 0) {
      if (name === 'error') throw unhandledError(args[0]);
      return false;
    }

    // Snapshot: listeners added from a callback must not run in this emit.
    const handlers = list.slice();
    for (const handler of handlers) handler.apply(this, args);
    return true;
  }

  listeners(name) {
    const list = this._events.get(name);
    if (list === undefined) return [];
    return list.map((listener) => unwrap(listener));
  }

  rawListeners(name) {
    const list = this._events.get(name);
    return list === undefined ? [] : list.slice();
  }

  listenerCount(name, listener) {
    const list = this._events.get(name);
    if (list === undefined) return 0;
    if (listener === undefined) return list.length;
    let count = 0;
    for (const entry of list) {
      if (unwrap(entry) === listener) count++;
    }
    return count;
  }

  eventNames() {
    return Array.from(this._events.keys());
  }

  setMaxListeners(count) {
    if (typeof count !== 'number' || Number.isNaN(count) || count < 0) {
      const error = new RangeError(`The value of "n" is out of range. It must be a non-negative number. Received ${count}`);
      error.code = 'ERR_OUT_OF_RANGE';
      throw error;
    }
    this._maxListeners = count;
    return this;
  }

  getMaxListeners() {
    return this._maxListeners === undefined ? EventEmitter.defaultMaxListeners : this._maxListeners;
  }
}

EventEmitter.defaultMaxListeners = 10;
EventEmitter.EventEmitter = EventEmitter;

function abortError() {
  const error = new Error('The operation was aborted');
  error.name = 'AbortError';
  error.code = 'ABORT_ERR';
  return error;
}

function once(emitter, name, options) {
  return new Promise((resolve, reject) => {
    if (emitter === null || typeof emitter.on !== 'function' || typeof emitter.removeListener !== 'function') {
      reject(invalidArgType('emitter', 'EventEmitter', emitter));
      return;
    }

    let signal;
    if (options !== undefined) {
      if (options === null || typeof options !== 'object') {
        reject(invalidArgType('options', 'object', options));
        return;
      }
      signal = options.signal;
    }

    if (signal !== undefined) {
      if (signal === null || typeof signal.addEventListener !== 'function' || typeof signal.removeEventListener !== 'function') {
        reject(invalidArgType('options.signal', 'AbortSignal', signal));
        return;
      }
      if (signal.aborted) {
        reject(abortError());
        return;
      }
    }

    let settled = false;
    const cleanup = () => {
      emitter.removeListener(name, resolver);
      if (name !== 'error') emitter.removeListener('error', errorListener);
      if (signal !== undefined) signal.removeEventListener('abort', onAbort);
    };
    const resolver = (...args) => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(args);
    };
    const errorListener = (error) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(error);
    };
    const onAbort = () => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(abortError());
    };

    emitter.on(name, resolver);
    if (name !== 'error') emitter.on('error', errorListener);
    if (signal !== undefined) signal.addEventListener('abort', onAbort);
  });
}

EventEmitter.once = once;

export { EventEmitter, once };
export default EventEmitter;
