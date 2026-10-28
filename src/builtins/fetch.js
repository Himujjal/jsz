// WHATWG fetch facade. The native side buffers the response body; streaming
// bodies and in-flight cancellation are intentionally out of scope for v1.

import * as native from 'node:_fetch';
import { Buffer } from 'node:buffer';
import { TextDecoder } from 'node:util';

const HTTP_SCHEMES = new Set(['http:', 'https:']);

function invalidArgument(name, expected) {
  const error = new TypeError(`The "${name}" argument must be ${expected}`);
  error.code = 'ERR_INVALID_ARG_TYPE';
  return error;
}

function toHeaderName(name) {
  const text = String(name);
  if (text.length === 0) {
    const error = new TypeError('Header name must be a non-empty string');
    error.code = 'ERR_INVALID_HTTP_TOKEN';
    throw error;
  }
  return text.toLowerCase();
}

function toHeaderValue(value) {
  const text = String(value);
  if (text.includes('\r') || text.includes('\n')) {
    const error = new TypeError('Header value contains an invalid character');
    error.code = 'ERR_INVALID_CHAR';
    throw error;
  }
  return text;
}

function consumedError() {
  const error = new TypeError('Body is unusable: Body has already been read');
  error.code = 'ERR_BODY_ALREADY_READ';
  return error;
}

function abortError() {
  const error = new Error('This operation was aborted');
  error.name = 'AbortError';
  error.code = 'ABORT_ERR';
  return error;
}

function toBytes(body, name) {
  if (body === undefined || body === null) return new Uint8Array(0);
  if (typeof body === 'string') return new Uint8Array(Buffer.from(body, 'utf8'));
  if (body instanceof ArrayBuffer) return new Uint8Array(body.slice(0));
  if (body instanceof Uint8Array) return new Uint8Array(body);
  if (ArrayBuffer.isView(body)) {
    return new Uint8Array(body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength));
  }
  throw invalidArgument(name, 'a string, Buffer, Uint8Array, or ArrayBuffer');
}

export class Headers {
  constructor(init) {
    this._map = new Map();
    if (init === undefined || init === null) return;

    if (init instanceof Headers) {
      init.forEach((value, name) => this.append(name, value));
      return;
    }

    if (Array.isArray(init)) {
      if (init.length === 0) return;
      if (Array.isArray(init[0])) {
        for (const pair of init) {
          if (!Array.isArray(pair) || pair.length < 2) {
            throw invalidArgument('headers', 'an array of [name, value] pairs');
          }
          this.append(pair[0], pair[1]);
        }
        return;
      }
      if (init.length % 2 !== 0) {
        throw invalidArgument('headers', 'an even-length array of name/value pairs');
      }
      for (let index = 0; index < init.length; index += 2) {
        this.append(init[index], init[index + 1]);
      }
      return;
    }

    if (typeof init === 'object') {
      for (const name of Object.keys(init)) this.append(name, init[name]);
      return;
    }

    throw invalidArgument('headers', 'an object, an array, or another Headers instance');
  }

  append(name, value) {
    const key = toHeaderName(name);
    const text = toHeaderValue(value);
    const current = this._map.get(key);
    if (current === undefined) this._map.set(key, [text]);
    else current.push(text);
  }

  set(name, value) {
    this._map.set(toHeaderName(name), [toHeaderValue(value)]);
  }

  get(name) {
    const values = this._map.get(toHeaderName(name));
    return values === undefined ? null : values.join(', ');
  }

  getAll(name) {
    const values = this._map.get(toHeaderName(name));
    return values === undefined ? [] : values.slice();
  }

  getSetCookie() {
    const values = this._map.get('set-cookie');
    return values === undefined ? [] : values.slice();
  }

  has(name) {
    return this._map.has(toHeaderName(name));
  }

  delete(name) {
    this._map.delete(toHeaderName(name));
  }

  forEach(callback, thisArg) {
    for (const [name, values] of this._map) {
      callback.call(thisArg, values.join(', '), name, this);
    }
  }

  entries() {
    const list = [];
    for (const [name, values] of this._map) list.push([name, values.join(', ')]);
    return list[Symbol.iterator]();
  }

  keys() {
    const list = [];
    for (const name of this._map.keys()) list.push(name);
    return list[Symbol.iterator]();
  }

  values() {
    const list = [];
    for (const values of this._map.values()) list.push(values.join(', '));
    return list[Symbol.iterator]();
  }

  [Symbol.iterator]() {
    return this.entries();
  }
}

export class Response {
  constructor(body, init) {
    const options = init === undefined || init === null ? {} : init;
    this.status = typeof options.status === 'number' ? options.status : 200;
    this.statusText = options.statusText === undefined ? '' : String(options.statusText);
    this.ok = this.status >= 200 && this.status <= 299;
    this.url = options.url === undefined ? '' : String(options.url);
    this.redirected = options.redirected === true;
    this.type = 'basic';
    this.headers = options.headers instanceof Headers ? options.headers : new Headers(options.headers);
    this.bodyUsed = false;
    this._body = toBytes(body, 'body');
  }

  _consume() {
    if (this.bodyUsed) throw consumedError();
    this.bodyUsed = true;
    return this._body;
  }

  async text() {
    return new TextDecoder().decode(this._consume());
  }

  async json() {
    return JSON.parse(await this.text());
  }

  async arrayBuffer() {
    const bytes = this._consume();
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  }

  async bytes() {
    return new Uint8Array(this._consume());
  }

  clone() {
    if (this.bodyUsed) throw consumedError();
    return new Response(this._body, {
      status: this.status,
      statusText: this.statusText,
      url: this.url,
      redirected: this.redirected,
      headers: new Headers(this.headers),
    });
  }
}

export class Request {
  constructor(input, init) {
    const options = init === undefined || init === null ? {} : init;
    if (typeof input === 'string') this.url = input;
    else if (input !== null && typeof input === 'object' && typeof input.href === 'string') this.url = input.href;
    else this.url = String(input);

    this.method = options.method === undefined ? 'GET' : String(options.method).toUpperCase();
    this.headers = options.headers instanceof Headers ? options.headers : new Headers(options.headers);
    this.body = options.body === undefined ? null : options.body;
    this.signal = options.signal === undefined ? null : options.signal;
    this.redirect = options.redirect === undefined ? 'follow' : String(options.redirect);
  }
}

function parseUrl(input) {
  let text;
  if (typeof input === 'string') text = input;
  else if (input !== null && typeof input === 'object' && typeof input.href === 'string') text = input.href;
  else text = String(input);

  let url;
  try {
    url = new URL(text);
  } catch {
    throw new TypeError(`Failed to parse URL from ${text}`);
  }
  if (!HTTP_SCHEMES.has(url.protocol)) {
    throw new TypeError(`Failed to parse URL from ${text}: unsupported protocol`);
  }
  return url;
}

function parseMethod(init) {
  if (init === undefined || init === null || init.method === undefined) return 'GET';
  const method = String(init.method).toUpperCase();
  if (method.length === 0) {
    const error = new TypeError('Request method "" is not a valid HTTP method');
    error.code = 'ERR_INVALID_HTTP_TOKEN';
    throw error;
  }
  return method;
}

function parseRedirect(init) {
  if (init === undefined || init === null || init.redirect === undefined) return 5;
  const mode = String(init.redirect);
  if (mode === 'follow') return 5;
  if (mode === 'manual' || mode === 'error') return 0;
  throw new TypeError(`Invalid redirect mode: ${mode}`);
}

function encodeBody(body) {
  if (body === undefined || body === null) return null;
  if (typeof body === 'string') return new Uint8Array(Buffer.from(body, 'utf8'));
  if (body instanceof ArrayBuffer) return new Uint8Array(body.slice(0));
  if (body instanceof Uint8Array) return new Uint8Array(body);
  if (ArrayBuffer.isView(body)) {
    return new Uint8Array(body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength));
  }
  throw invalidArgument('body', 'a string, Buffer, Uint8Array, or ArrayBuffer');
}

function flattenHeaders(headers) {
  const pairs = [];
  for (const [name, value] of headers) pairs.push(name, value);
  return pairs;
}

function nextRequestId() {
  const current = typeof globalThis.__jszNextRequestId === 'number' ? globalThis.__jszNextRequestId : 1;
  globalThis.__jszNextRequestId = current + 1;
  return current;
}

function isRedirect(status) {
  return status === 301 || status === 302 || status === 303 || status === 307 || status === 308;
}

function headerFromRaw(rawHeaders, wanted) {
  for (let index = 0; index + 1 < rawHeaders.length; index += 2) {
    if (String(rawHeaders[index]).toLowerCase() === wanted) return String(rawHeaders[index + 1]);
  }
  return null;
}

function sameOrigin(a, b) {
  return a.protocol === b.protocol && a.hostname === b.hostname && a.port === b.port;
}

function stripBodyHeaders(headers) {
  headers.delete('content-length');
  headers.delete('content-type');
  headers.delete('content-encoding');
  headers.delete('transfer-encoding');
}

function stripSensitiveHeaders(headers) {
  headers.delete('authorization');
  headers.delete('cookie');
  headers.delete('proxy-authorization');
}

function redirectMethod(status, method) {
  if (status === 303) return method !== 'GET' && method !== 'HEAD';
  if (status === 301 || status === 302) return method === 'POST';
  return false;
}

async function requestOnce(url, method, headers, body, signal) {
  const id = nextRequestId();
  let listener = null;

  if (signal !== undefined && signal !== null) {
    if (signal.aborted) throw abortError();
    if (typeof signal.addEventListener === 'function') {
      listener = () => {
        native.abort(id);
      };
      signal.addEventListener('abort', listener);
    }
  }

  try {
    const raw = await native.fetch(url.href, method, flattenHeaders(headers), body, 0, id);
    if (signal !== undefined && signal !== null && signal.aborted) throw abortError();
    return raw;
  } catch (error) {
    if (error !== null && typeof error === 'object' && error.code === 'ABORT_ERR') throw abortError();
    throw error;
  } finally {
    if (listener !== null) signal.removeEventListener('abort', listener);
  }
}

export async function fetch(input, init) {
  const options = init === undefined || init === null ? {} : init;
  const url = parseUrl(input);
  const signal = options.signal;
  if (signal !== undefined && signal !== null && signal.aborted) throw abortError();

  let method = parseMethod(options);
  let headers = options.headers instanceof Headers ? new Headers(options.headers) : new Headers(options.headers);
  let body = encodeBody(options.body);
  const redirectMode = options.redirect === undefined ? 'follow' : String(options.redirect);
  let current = url;
  let redirected = false;
  let hops = 0;

  while (true) {
    const raw = await requestOnce(current, method, headers, body, signal);
    const location = isRedirect(raw.status) ? headerFromRaw(raw.headers, 'location') : null;

    if (location === null) {
      return new Response(raw.body, {
        status: raw.status,
        statusText: raw.statusText,
        url: current.href,
        redirected,
        headers: new Headers(raw.headers),
      });
    }

    if (redirectMode === 'error') {
      const error = new TypeError('fetch failed: redirect mode is set to error');
      error.code = 'ERR_FETCH_REDIRECT';
      throw error;
    }
    if (redirectMode === 'manual' || hops >= 5) {
      if (hops >= 5 && redirectMode !== 'manual') {
        const error = new TypeError('fetch failed: redirect count exceeded');
        error.code = 'ERR_FETCH_REDIRECT';
        throw error;
      }
      return new Response(raw.body, {
        status: raw.status,
        statusText: raw.statusText,
        url: current.href,
        redirected,
        headers: new Headers(raw.headers),
      });
    }

    let next;
    try {
      next = new URL(location, current);
    } catch {
      const error = new TypeError(`fetch failed: invalid redirect location ${location}`);
      error.code = 'ERR_FETCH_REDIRECT';
      throw error;
    }
    if (!HTTP_SCHEMES.has(next.protocol)) {
      const error = new TypeError(`fetch failed: unsupported redirect protocol ${next.protocol}`);
      error.code = 'ERR_FETCH_REDIRECT';
      throw error;
    }

    if (redirectMethod(raw.status, method)) {
      method = 'GET';
      body = null;
      stripBodyHeaders(headers);
    }
    if (!sameOrigin(current, next)) stripSensitiveHeaders(headers);

    current = next;
    redirected = true;
    hops += 1;
  }
}

export default { fetch, Headers, Response, Request };
