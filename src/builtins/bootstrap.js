// Installs the Node-compatible globals that are built from ESM sources.
import process from 'node:process';
import { Buffer, atob, btoa } from 'node:buffer';
import { TextEncoder, TextDecoder } from 'node:util';
import { webcrypto } from 'node:crypto';
import { URL, URLSearchParams } from 'node:url';
import EventEmitter from 'node:events';
import { fetch, Headers, Response, Request } from 'node:http';
import console from 'node:console';

globalThis.console = console;

// `performance.now` is monotonic milliseconds over `process.hrtime.bigint()`;
// `timeOrigin` is a fixed wall-clock anchor taken once, like the browser API.
function performanceNow() {
  return Number(process.hrtime.bigint()) / 1e6;
}

globalThis.performance = {
  now: performanceNow,
  timeOrigin: Date.now() - performanceNow(),
};

// Node exposes the global object as `global`.
globalThis.global = globalThis;

globalThis.fetch = fetch;
globalThis.Headers = Headers;
globalThis.Response = Response;
globalThis.Request = Request;

globalThis.process = process;
globalThis.Buffer = Buffer;
globalThis.atob = atob;
globalThis.btoa = btoa;
globalThis.TextEncoder = TextEncoder;
globalThis.TextDecoder = TextDecoder;
globalThis.crypto = webcrypto;
globalThis.URL = URL;
globalThis.URLSearchParams = URLSearchParams;

// QuickJS-ng ships no DOM, so `AbortController`/`AbortSignal` live here with
// just the surface child_process and timers need.

function abortError(reason) {
  const message = reason === undefined || reason === null ? 'This operation was aborted' : String(reason);
  const error = new Error(message);
  error.name = 'AbortError';
  error.code = 'ABORT_ERR';
  return error;
}

class AbortSignal extends EventEmitter {
  constructor() {
    super();
    this.aborted = false;
    this.reason = undefined;
    this.onabort = null;
  }

  addEventListener(type, listener, options) {
    if (options !== undefined && options !== null && options.once) this.once(type, listener);
    else this.on(type, listener);
  }

  removeEventListener(type, listener) {
    this.off(type, listener);
  }

  throwIfAborted() {
    if (this.aborted) throw this.reason;
  }

  static timeout(ms) {
    const controller = new AbortController();
    setTimeout(() => controller.abort(abortError()), ms);
    return controller.signal;
  }

  static abort(reason) {
    const controller = new AbortController();
    controller.abort(reason);
    return controller.signal;
  }
}

class AbortController {
  constructor() {
    this.signal = new AbortSignal();
  }

  abort(reason) {
    const signal = this.signal;
    if (signal.aborted) return;
    signal.aborted = true;
    signal.reason = reason === undefined ? abortError() : reason;
    if (typeof signal.onabort === 'function') signal.onabort();
    signal.emit('abort');
  }
}

globalThis.AbortController = AbortController;
globalThis.AbortSignal = AbortSignal;
