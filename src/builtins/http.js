// Node.js `node:http` subset: `createServer`, `request`/`get`, plus the
// WHATWG fetch facade.
//
// Server requests are buffered whole by the dusty handler (up to 1 MiB),
// dispatched to the JS task, and answered either once at `ServerResponse.end`
// (Content-Length) or incrementally from `write`/`flushHeaders` (chunked).
// Client responses stream: the native head settles first, then each body chunk
// is pulled with one `ack` per `data` listener read, so a paused response stops
// reading the wire. `server.close()` stops accepting and lets in-flight handlers
// finish through dusty's drain before emitting `close`.

import * as native from 'node:_http';
import * as requestNative from 'node:_fetch';
import * as pkcs12 from 'node:_pkcs12';
import { Buffer } from 'node:buffer';
import { EventEmitter } from 'node:events';
import { fetch, Headers, Request, Response } from 'node:_fetch_js';

export { fetch, Headers, Request, Response };

const MAX_HEADER_SIZE = 16 * 1024;

const STATUS_CODES = {
  100: 'Continue',
  101: 'Switching Protocols',
  102: 'Processing',
  103: 'Early Hints',
  200: 'OK',
  201: 'Created',
  202: 'Accepted',
  203: 'Non-Authoritative Information',
  204: 'No Content',
  205: 'Reset Content',
  206: 'Partial Content',
  207: 'Multi-Status',
  208: 'Already Reported',
  226: 'IM Used',
  300: 'Multiple Choices',
  301: 'Moved Permanently',
  302: 'Found',
  303: 'See Other',
  304: 'Not Modified',
  305: 'Use Proxy',
  307: 'Temporary Redirect',
  308: 'Permanent Redirect',
  400: 'Bad Request',
  401: 'Unauthorized',
  402: 'Payment Required',
  403: 'Forbidden',
  404: 'Not Found',
  405: 'Method Not Allowed',
  406: 'Not Acceptable',
  407: 'Proxy Authentication Required',
  408: 'Request Timeout',
  409: 'Conflict',
  410: 'Gone',
  411: 'Length Required',
  412: 'Precondition Failed',
  413: 'Payload Too Large',
  414: 'URI Too Long',
  415: 'Unsupported Media Type',
  416: 'Range Not Satisfiable',
  417: 'Expectation Failed',
  418: "I'm a Teapot",
  421: 'Misdirected Request',
  422: 'Unprocessable Entity',
  423: 'Locked',
  424: 'Failed Dependency',
  425: 'Too Early',
  426: 'Upgrade Required',
  428: 'Precondition Required',
  429: 'Too Many Requests',
  431: 'Request Header Fields Too Large',
  451: 'Unavailable For Legal Reasons',
  500: 'Internal Server Error',
  501: 'Not Implemented',
  502: 'Bad Gateway',
  503: 'Service Unavailable',
  504: 'Gateway Timeout',
  505: 'HTTP Version Not Supported',
  506: 'Variant Also Negotiates',
  507: 'Insufficient Storage',
  508: 'Loop Detected',
  510: 'Not Extended',
  511: 'Network Authentication Required',
};

const METHODS = [
  'ACL',
  'BIND',
  'CHECKOUT',
  'CONNECT',
  'COPY',
  'DELETE',
  'GET',
  'HEAD',
  'LINK',
  'LOCK',
  'M-SEARCH',
  'MERGE',
  'MKACTIVITY',
  'MKCALENDAR',
  'MKCOL',
  'MOVE',
  'NOTIFY',
  'OPTIONS',
  'PATCH',
  'POST',
  'PROPFIND',
  'PROPPATCH',
  'PURGE',
  'PUT',
  'REBIND',
  'REPORT',
  'SEARCH',
  'SOURCE',
  'SUBSCRIBE',
  'TRACE',
  'UNBIND',
  'UNLINK',
  'UNLOCK',
  'UNSUBSCRIBE',
];

const TOKEN_RE = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;

const servers = new Map();
// connId -> { req, res } for the request currently awaiting a response.
const pending = new Map();

function invalidArgType(name, expected, value) {
  const error = new TypeError(`The "${name}" argument must be of type ${expected}. Received ${typeof value}`);
  error.code = 'ERR_INVALID_ARG_TYPE';
  return error;
}

function emitSafely(emitter, name, ...args) {
  try {
    emitter.emit(name, ...args);
  } catch (error) {
    // Never unwind into the native dispatch frame; report like an async throw.
    queueMicrotask(() => {
      throw error;
    });
  }
}

function nativeError(payload) {
  const error = new Error(payload.message);
  if (payload.code !== undefined) error.code = payload.code;
  if (payload.errno !== undefined) error.errno = payload.errno;
  if (payload.syscall !== undefined) error.syscall = payload.syscall;
  return error;
}

function validateHeaderName(name) {
  const text = typeof name === 'string' ? name : String(name);
  if (!TOKEN_RE.test(text)) {
    const error = new TypeError(`Invalid header name: ${text}`);
    error.code = 'ERR_INVALID_HTTP_TOKEN';
    throw error;
  }
  return text;
}

function validateHeaderValue(name, value) {
  if (value === undefined || value === null) {
    const error = new TypeError(`Invalid value "${String(value)}" for header "${name}"`);
    error.code = 'ERR_HTTP_INVALID_HEADER_VALUE';
    throw error;
  }
  const text = String(value);
  if (/[\r\n]/.test(text)) {
    const error = new TypeError(`Invalid character in header content ["${name}"]`);
    error.code = 'ERR_INVALID_CHAR';
    throw error;
  }
  return text;
}

function headerValue(value) {
  if (Array.isArray(value)) return value.map((entry) => String(entry)).join(', ');
  return String(value);
}

function validateStatus(code) {
  // 1xx interim responses are not supported: the native layer answers with
  // a single final response only.
  if (!Number.isInteger(code) || code < 100 || code > 999) {
    const error = new RangeError(`Invalid status code: ${code}`);
    error.code = 'ERR_HTTP_INVALID_STATUS_CODE';
    throw error;
  }
  return code;
}

class IncomingMessage extends EventEmitter {
  constructor(payload) {
    super();
    // `streamId` marks a client response whose body is still on the wire. The
    // server path (`payload.body`) keeps the buffered replay below.
    this._streaming = typeof payload.streamId === 'number';
    this._id = this._streaming ? payload.streamId : 0;

    this.method = payload.method;
    this.url = payload.url;
    this.statusCode = payload.statusCode;
    this.statusMessage = payload.statusMessage;
    this.httpVersion = payload.httpVersion === undefined ? '1.1' : payload.httpVersion;
    this.httpVersionMajor = this.httpVersion === '1.0' ? 1 : 1;
    this.httpVersionMinor = this.httpVersion === '1.0' ? 0 : 1;
    this.rawHeaders = payload.headers.slice();
    this.headers = {};
    for (let index = 0; index + 1 < this.rawHeaders.length; index += 2) {
      const name = String(this.rawHeaders[index]).toLowerCase();
      const value = String(this.rawHeaders[index + 1]);
      this.headers[name] = this.headers[name] === undefined ? value : `${this.headers[name]}, ${value}`;
    }
    this.complete = !this._streaming;
    this.readable = true;
    this.destroyed = false;
    this.aborted = false;
    this.keepAlive = payload.keepAlive === true;
    this.socket = {
      remoteAddress: payload.remoteAddress,
      remotePort: payload.remotePort,
      localAddress: payload.localAddress,
      localPort: payload.localPort,
      destroyed: false,
      readable: true,
      writable: true,
    };

    this._body = this._streaming ? null : Buffer.from(payload.body);
    this._encoding = null;
    this._paused = false;
    this._consumed = this._streaming;
    this._scheduled = false;

    // Streaming state. `_outstanding` tracks the single ack in flight: the
    // native task reads exactly one chunk per ack, so acking twice would let
    // the body run ahead of a paused consumer.
    this._queue = [];
    this._started = false;
    this._ended = false;
    this._outstanding = false;
    this._aborted = false;
    this._emitting = false;
    this._draining = false;
  }

  setEncoding(encoding) {
    // Queued chunks are kept as bytes, so the new encoding applies to them too.
    this._encoding = encoding === undefined || encoding === null ? null : String(encoding);
    return this;
  }

  pause() {
    this._paused = true;
    return this;
  }

  resume() {
    if (!this._streaming) {
      if (!this._paused) return this;
      this._paused = false;
      this._scheduleReplay();
      return this;
    }
    this._paused = false;
    // Node's `resume()` flows even with no listener, discarding the body;
    // otherwise an unconsumed response would hold the native task forever.
    if (this.listenerCount('data') === 0) this._draining = true;
    this._startStream();
    this._pump();
    return this;
  }

  destroy() {
    if (this.destroyed) return this;
    if (!this._streaming) {
      // The whole body is already buffered, so there is nothing to release.
      return this;
    }
    this.destroyed = true;
    this.aborted = true;
    this.readable = false;
    this._queue = [];
    if (!this._aborted) {
      this._aborted = true;
      requestNative.abort(this._id);
    }
    emitSafely(this, 'close');
    return this;
  }

  on(event, listener) {
    super.on(event, listener);
    if (this._streaming) {
      if (event === 'data') {
        this._draining = false;
        this._startStream();
        this._pump();
      }
    } else if (event === 'data' || event === 'end') {
      this._scheduleReplay();
    }
    return this;
  }

  addListener(event, listener) {
    return this.on(event, listener);
  }

  once(event, listener) {
    super.once(event, listener);
    if (this._streaming) {
      if (event === 'data') {
        this._draining = false;
        this._startStream();
        this._pump();
      }
    } else if (event === 'data' || event === 'end') {
      this._scheduleReplay();
    }
    return this;
  }

  _scheduleReplay() {
    if (this._scheduled || this._consumed) return;
    this._scheduled = true;
    queueMicrotask(() => {
      this._scheduled = false;
      if (this._consumed || this._paused) return;
      this._consumed = true;

      const chunk = this._encoding === null ? this._body : this._body.toString(this._encoding);
      if (chunk.length > 0) emitSafely(this, 'data', chunk);
      this.readable = false;
      emitSafely(this, 'end');
    });
  }

  /// First read request: the native task is waiting for one ack before it
  /// touches the wire at all.
  _startStream() {
    if (!this._streaming || this._started || this._ended || this.destroyed) return;
    this._started = true;
    this._ack();
  }

  _ack() {
    this._outstanding = true;
    if (!requestNative.ack(this._id)) this._outstanding = false;
  }

  _emitChunk(bytes) {
    const chunk = this._encoding === null ? bytes : bytes.toString(this._encoding);
    this._emitting = true;
    try {
      emitSafely(this, 'data', chunk);
    } finally {
      this._emitting = false;
    }
  }

  /// Drains queued bytes while flowing, then grants one more read. Called when
  /// a listener appears or `resume()` lifts a pause.
  _pump() {
    if (!this._streaming || !this._started || this.destroyed || this._ended) return;
    // A listener calling `resume()` mid-chunk is a no-op; `_receiveChunk` acks.
    if (this._paused || this._emitting) return;

    while (this._queue.length > 0 && !this._paused) {
      this._emitChunk(this._queue.shift());
    }
    if (this._queue.length === 0 && !this._paused && !this._outstanding) this._ack();
  }

  _receiveChunk(bytes) {
    if (!this._streaming || this.destroyed) return;
    this._outstanding = false;

    const chunk = Buffer.from(bytes);
    if (this._paused) {
      this._queue.push(chunk);
      return;
    }
    if (this.listenerCount('data') === 0) {
      // A `resume()` with no listener is Node's discard mode; without one the
      // bytes wait, since acking here would pull the whole body into memory.
      if (this._draining) this._ack();
      else this._queue.push(chunk);
      return;
    }

    this._emitChunk(chunk);
    if (!this._paused) this._ack();
  }

  _receiveEnd() {
    if (!this._streaming || this._ended) return;
    this._ended = true;

    const queued = this._queue;
    this._queue = [];
    for (const bytes of queued) this._emitChunk(bytes);

    this.complete = true;
    this.readable = false;
    emitSafely(this, 'end');
    emitSafely(this, 'close');
  }

  _receiveError(error) {
    if (!this._streaming || this.destroyed) return;
    this.destroyed = true;
    this.readable = false;
    this._queue = [];
    emitSafely(this, 'error', error);
    emitSafely(this, 'close');
  }
}

class ServerResponse extends EventEmitter {
  constructor(connId, keepAlive) {
    super();
    this._connId = connId;
    this.statusCode = 200;
    this.statusMessage = undefined;
    this.headersSent = false;
    this.sendDate = true;
    this.writableEnded = false;
    this.finished = false;
    this.destroyed = false;
    this._keepAlive = keepAlive === true;
    this._headers = new Map();
    this._chunks = [];
    this._ended = false;
    this._streaming = false;
  }

  _assertHeadersNotSent(method) {
    if (this.headersSent) {
      const error = new Error(`Cannot ${method} headers after they are sent to the client`);
      error.code = 'ERR_HTTP_HEADERS_SENT';
      throw error;
    }
  }

  _statusMessage() {
    const text = String(this.statusMessage || STATUS_CODES[this.statusCode] || 'unknown');
    if (text.includes('\r') || text.includes('\n')) {
      const error = new TypeError('Invalid character in statusMessage');
      error.code = 'ERR_INVALID_CHAR';
      throw error;
    }
    return text;
  }

  _headerPairs() {
    const pairs = [];
    for (const entry of this._headers.values()) pairs.push(entry.name, entry.value);
    return pairs;
  }

  _startStream() {
    if (!native.streamStart(
      this._connId,
      this.statusCode,
      this._statusMessage(),
      this._headerPairs(),
      this._keepAlive,
    )) {
      return false;
    }
    this._streaming = true;
    this.headersSent = true;
    return true;
  }

  setHeader(name, value) {
    this._assertHeadersNotSent('set');
    const text = validateHeaderName(name);
    const key = text.toLowerCase();
    if (Array.isArray(value)) {
      for (const entry of value) validateHeaderValue(text, entry);
    } else {
      validateHeaderValue(text, value);
    }
    this._headers.set(key, { name: text, value: headerValue(value) });
    return this;
  }

  getHeader(name) {
    const entry = this._headers.get(String(name).toLowerCase());
    return entry === undefined ? undefined : entry.value;
  }

  getHeaders() {
    const result = {};
    for (const [key, entry] of this._headers) result[key] = entry.value;
    return result;
  }

  hasHeader(name) {
    return this._headers.has(String(name).toLowerCase());
  }

  removeHeader(name) {
    this._assertHeadersNotSent('remove');
    this._headers.delete(String(name).toLowerCase());
  }

  writeHead(statusCode, statusMessage, headers) {
    this._assertHeadersNotSent('write');
    this.statusCode = validateStatus(statusCode);
    if (typeof statusMessage === 'string') {
      this.statusMessage = statusMessage;
    } else if (statusMessage !== undefined && statusMessage !== null) {
      headers = statusMessage;
    }
    if (headers !== undefined && headers !== null) {
      if (Array.isArray(headers)) {
        for (let index = 0; index + 1 < headers.length; index += 2) {
          this.setHeader(headers[index], headers[index + 1]);
        }
      } else {
        for (const name of Object.keys(headers)) this.setHeader(name, headers[name]);
      }
    }
    return this;
  }

  flushHeaders() {
    if (this._ended || this.destroyed || this._streaming) {
      this.headersSent = true;
      return;
    }
    validateStatus(this.statusCode);
    this._startStream();
  }

  write(chunk, encoding, callback) {
    if (typeof encoding === 'function') {
      callback = encoding;
      encoding = undefined;
    }
    if (this._ended) {
      const error = new Error('write after end');
      error.code = 'ERR_STREAM_WRITE_AFTER_END';
      throw error;
    }
    if (this.destroyed) return false;

    const bytes = toBuffer(chunk, encoding);
    if (!this._streaming) {
      validateStatus(this.statusCode);
      if (!this._startStream()) return false;
    }

    const writable = native.streamWrite(this._connId, bytes);
    if (typeof callback === 'function') queueMicrotask(callback);
    return writable;
  }

  end(chunk, encoding, callback) {
    if (typeof chunk === 'function') {
      callback = chunk;
      chunk = undefined;
      encoding = undefined;
    } else if (typeof encoding === 'function') {
      callback = encoding;
      encoding = undefined;
    }
    if (this._ended) {
      // Node warns when `end` is called twice; we keep the first response.
      if (typeof callback === 'function') queueMicrotask(callback);
      return this;
    }
    if (this.destroyed) {
      if (typeof callback === 'function') queueMicrotask(callback);
      return this;
    }

    if (chunk !== undefined && chunk !== null) {
      const bytes = toBuffer(chunk, encoding);
      if (bytes.length > 0) this.write(bytes);
    }
    validateStatus(this.statusCode);
    const statusMessage = this._statusMessage();

    this._ended = true;
    this.writableEnded = true;
    this.finished = true;

    if (this._streaming) {
      native.streamEnd(this._connId);
      this.headersSent = true;
      queueMicrotask(() => emitSafely(this, 'finish'));
      if (typeof callback === 'function') queueMicrotask(callback);
      return this;
    }

    const body = Buffer.concat(this._chunks);
    native.respond(
      this._connId,
      this.statusCode,
      statusMessage,
      this._headerPairs(),
      body,
      this._keepAlive,
    );

    this.headersSent = true;
    queueMicrotask(() => emitSafely(this, 'finish'));
    if (typeof callback === 'function') queueMicrotask(callback);
    return this;
  }

  destroy(error) {
    if (this.destroyed) return this;
    this.destroyed = true;
    this._ended = true;
    this.writableEnded = true;
    native.streamAbort(this._connId);
    pending.delete(this._connId);
    if (error !== undefined && error !== null) emitSafely(this, 'error', error);
    queueMicrotask(() => emitSafely(this, 'close'));
    return this;
  }
}

function nextRequestId() {
  const current = typeof globalThis.__jszNextRequestId === 'number' ? globalThis.__jszNextRequestId : 1;
  globalThis.__jszNextRequestId = current + 1;
  return current;
}

function initHeaders(init) {
  const map = new Map();
  if (init === undefined || init === null) return map;

  const add = (name, value) => {
    const text = validateHeaderName(name);
    const key = text.toLowerCase();
    if (Array.isArray(value)) {
      for (const entry of value) validateHeaderValue(text, entry);
      map.set(key, { name: text, value: value.map((entry) => String(entry)).join(', ') });
    } else {
      validateHeaderValue(text, value);
      map.set(key, { name: text, value: String(value) });
    }
  };

  if (init instanceof Headers) {
    init.forEach((value, name) => add(name, value));
  } else if (Array.isArray(init)) {
    if (init.length > 0 && Array.isArray(init[0])) {
      for (const pair of init) add(pair[0], pair[1]);
    } else {
      for (let index = 0; index + 1 < init.length; index += 2) add(init[index], init[index + 1]);
    }
  } else if (typeof init === 'object') {
    for (const name of Object.keys(init)) add(name, init[name]);
  }
  return map;
}

function formatHost(hostname) {
  if (hostname.startsWith('[') && hostname.endsWith(']')) return hostname;
  return hostname.includes(':') ? `[${hostname}]` : hostname;
}

function requestSetup(input, options, secure) {
  const scheme = secure === true;
  const defaultProtocol = scheme ? 'https:' : 'http:';
  const defaultPort = scheme ? 443 : 80;

  let base = null;
  if (typeof input === 'string') {
    base = new URL(input);
    options = options === undefined || options === null ? {} : options;
  } else if (input !== null && typeof input === 'object' && typeof input.href === 'string') {
    base = new URL(input.href);
    options = options === undefined || options === null ? {} : options;
  } else {
    options = input === undefined || input === null ? {} : input;
  }

  const protocol = options.protocol === undefined
    ? (base === null ? defaultProtocol : base.protocol)
    : String(options.protocol);
  if (!/^[a-z][a-z0-9+.-]*:$/i.test(protocol)) {
    throw invalidArgType('protocol', 'string', protocol);
  }
  if (protocol !== defaultProtocol) {
    const error = new TypeError(`Protocol "${protocol}" not supported. Expected "${defaultProtocol}"`);
    error.code = 'ERR_INVALID_PROTOCOL';
    throw error;
  }

  let hostname = options.hostname;
  let port = options.port;
  if (hostname === undefined && typeof options.host === 'string') {
    const host = options.host;
    if (host.startsWith('[')) {
      const end = host.indexOf(']');
      if (end < 0) throw invalidArgType('host', 'string', host);
      hostname = host.slice(0, end + 1);
      if (port === undefined && host[end + 1] === ':') port = host.slice(end + 2);
    } else {
      const colon = host.lastIndexOf(':');
      if (colon > 0 && /^\d+$/.test(host.slice(colon + 1))) {
        hostname = host.slice(0, colon);
        if (port === undefined) port = host.slice(colon + 1);
      } else {
        hostname = host;
      }
    }
  }
  if (hostname === undefined) hostname = base === null ? 'localhost' : base.hostname;
  if (port === undefined) {
    port = base === null || base.port === '' ? defaultPort : Number(base.port);
  }
  port = Number(port);
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    const error = new RangeError(`The value of "port" is out of range. It must be >= 0 and <= 65535. Received ${port}`);
    error.code = 'ERR_SOCKET_BAD_PORT';
    throw error;
  }

  let path = options.path;
  if (path === undefined) path = base === null ? '/' : `${base.pathname}${base.search}`;
  path = String(path);
  if (!path.startsWith('/')) path = `/${path}`;

  const method = options.method === undefined ? 'GET' : String(options.method).toUpperCase();
  const timeout = typeof options.timeout === 'number' && Number.isFinite(options.timeout) && options.timeout > 0
    ? Math.floor(options.timeout)
    : 0;

  let href = `${protocol}//${formatHost(String(hostname))}`;
  if (port !== defaultPort) href += `:${port}`;
  href += path;

  const headers = initHeaders(options.headers);
  if (options.auth !== undefined && !headers.has('authorization')) {
    const token = Buffer.from(String(options.auth), 'utf8').toString('base64');
    headers.set('authorization', { name: 'Authorization', value: `Basic ${token}` });
  }

  return { url: new URL(href), method, headers, timeout, path, options };
}

function pemText(value, name) {
  if (typeof value === 'string') return value;
  if (ArrayBuffer.isView(value)) {
    return Buffer.from(value.buffer, value.byteOffset, value.byteLength).toString('utf8');
  }
  throw invalidArgType(name, 'string or Buffer', value);
}

function pfxBytes(value) {
  if (typeof value === 'string') return Buffer.from(value, 'latin1');
  if (ArrayBuffer.isView(value)) {
    return Buffer.from(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
  }
  throw invalidArgType('pfx', 'string, Buffer, or Uint8Array', value);
}

/// Maps `https.request` options onto the native TLS payload. `null` means the
/// shared default client. `servername` is accepted but unused: dusty derives the
/// name from the URL.
function tlsOptions(options) {
  const tls = {};
  let present = false;

  if (options.ca !== undefined && options.ca !== null) {
    tls.ca = Array.isArray(options.ca)
      ? options.ca.map((entry) => pemText(entry, 'ca')).join('\n')
      : pemText(options.ca, 'ca');
    present = true;
  }

  if (options.pfx !== undefined && options.pfx !== null) {
    // A PFX bundle carries both halves, so it wins over separate cert/key.
    const passphrase = options.passphrase === undefined || options.passphrase === null
      ? ''
      : String(options.passphrase);
    const bundle = pkcs12.parse(pfxBytes(options.pfx), passphrase);
    tls.cert = bundle.cert;
    tls.key = bundle.key;
    present = true;
  } else {
    const hasCert = options.cert !== undefined && options.cert !== null;
    const hasKey = options.key !== undefined && options.key !== null;
    if (hasCert !== hasKey) {
      const error = new TypeError('The TLS "cert" and "key" options must be provided together');
      error.code = 'ERR_INVALID_ARG_VALUE';
      throw error;
    }
    if (hasCert) {
      tls.cert = pemText(options.cert, 'cert');
      tls.key = pemText(options.key, 'key');
      present = true;
    }
  }

  if (options.rejectUnauthorized === false) {
    tls.rejectUnauthorized = false;
    present = true;
  }

  return present ? tls : null;
}

class ClientRequest extends EventEmitter {
  constructor(input, options, secure) {
    super();
    this._secure = secure === true;
    const setup = requestSetup(input, options, this._secure);
    this._url = setup.url;
    this.path = setup.path;
    this.method = setup.method;
    this._headers = setup.headers;
    this._tls = this._secure ? tlsOptions(setup.options) : null;
    this._chunks = [];
    this._ended = false;
    this._started = false;
    this._id = nextRequestId();
    this._timer = null;
    this.timeout = setup.timeout;
    this.aborted = false;
    this.destroyed = false;
    this.headersSent = false;
    this.writableEnded = false;
    this.finished = false;
    this.socket = null;
    this.res = null;
  }

  setHeader(name, value) {
    const text = validateHeaderName(name);
    const key = text.toLowerCase();
    if (Array.isArray(value)) {
      for (const entry of value) validateHeaderValue(text, entry);
      this._headers.set(key, { name: text, value: value.map((entry) => String(entry)).join(', ') });
    } else {
      validateHeaderValue(text, value);
      this._headers.set(key, { name: text, value: String(value) });
    }
    return this;
  }

  getHeader(name) {
    const entry = this._headers.get(String(name).toLowerCase());
    return entry === undefined ? undefined : entry.value;
  }

  getHeaders() {
    const result = {};
    for (const [key, entry] of this._headers) result[key] = entry.value;
    return result;
  }

  getHeaderNames() {
    return Array.from(this._headers.keys());
  }

  hasHeader(name) {
    return this._headers.has(String(name).toLowerCase());
  }

  removeHeader(name) {
    this._headers.delete(String(name).toLowerCase());
  }

  write(chunk, encoding, callback) {
    if (typeof encoding === 'function') {
      callback = encoding;
      encoding = undefined;
    }
    if (this._ended || this.destroyed) {
      const error = new Error('write after end');
      error.code = 'ERR_STREAM_WRITE_AFTER_END';
      emitSafely(this, 'error', error);
      return false;
    }
    this._chunks.push(toBuffer(chunk, encoding));
    if (typeof callback === 'function') queueMicrotask(callback);
    return true;
  }

  end(chunk, encoding, callback) {
    if (typeof chunk === 'function') {
      callback = chunk;
      chunk = undefined;
      encoding = undefined;
    } else if (typeof encoding === 'function') {
      callback = encoding;
      encoding = undefined;
    }
    if (this._ended) {
      if (typeof callback === 'function') queueMicrotask(callback);
      return this;
    }
    if (chunk !== undefined && chunk !== null) this.write(chunk, encoding);

    this._ended = true;
    this.writableEnded = true;
    this.finished = true;
    this._start();
    queueMicrotask(() => emitSafely(this, 'finish'));
    if (typeof callback === 'function') queueMicrotask(callback);
    return this;
  }

  flushHeaders() {
    this.headersSent = true;
  }

  abort() {
    return this.destroy();
  }

  destroy(error) {
    if (this.destroyed) return this;
    this.destroyed = true;
    this.aborted = true;
    if (this._timer !== null) {
      clearTimeout(this._timer);
      this._timer = null;
    }
    if (error !== undefined && error !== null) emitSafely(this, 'error', error);
    if (this.res !== null) {
      // The response owns the streaming abort and emits `close` for both.
      this.res.destroy();
    } else if (this._started) {
      requestNative.abort(this._id);
    }
    // A started request settles through the native task: the head promise
    // resolves or rejects, or the response's `close` forwards to this one.
    if (!this._started) queueMicrotask(() => emitSafely(this, 'close'));
    return this;
  }

  setTimeout(ms, callback) {
    this.timeout = typeof ms === 'number' && Number.isFinite(ms) && ms > 0 ? Math.floor(ms) : 0;
    if (typeof callback === 'function') this.once('timeout', callback);
    return this;
  }

  _start() {
    if (this._started || this.destroyed) return;
    this._started = true;

    const body = Buffer.concat(this._chunks);
    const pairs = [];
    for (const entry of this._headers.values()) pairs.push(entry.name, entry.value);

    if (this.timeout > 0) {
      this._timer = setTimeout(() => {
        emitSafely(this, 'timeout');
        this.destroy();
      }, this.timeout);
    }

    // The native job owns these callbacks for its lifetime; each one forwards to
    // the response created once the head settles.
    const onChunk = (bytes) => {
      const res = this.res;
      if (res === null) return;
      res._receiveChunk(bytes);
    };
    const onEnd = () => {
      const res = this.res;
      if (res === null) return;
      res._receiveEnd();
    };
    const onError = (error) => {
      const res = this.res;
      if (res === null) return;
      res._receiveError(error);
    };

    requestNative.request(
      this._url.href,
      this.method,
      pairs,
      body.length > 0 ? body : null,
      this.timeout,
      this._id,
      this._tls,
      onChunk,
      onEnd,
      onError,
    ).then((raw) => {
      if (this._timer !== null) {
        clearTimeout(this._timer);
        this._timer = null;
      }
      if (this.destroyed) {
        emitSafely(this, 'close');
        return;
      }

      const res = new IncomingMessage({
        statusCode: raw.status,
        statusMessage: raw.statusText,
        headers: raw.headers,
        streamId: this._id,
        method: this.method,
        url: this.path,
        httpVersion: '1.1',
        remoteAddress: this._url.hostname,
        remotePort: Number(this._url.port === '' ? (this._secure ? 443 : 80) : this._url.port),
        keepAlive: true,
      });
      res.req = this;
      this.res = res;
      this.headersSent = true;

      let closed = false;
      const closeRequest = () => {
        if (closed) return;
        closed = true;
        emitSafely(this, 'close');
      };
      res.once('end', closeRequest);
      res.once('close', closeRequest);

      emitSafely(this, 'response', res);
    }).catch((error) => {
      if (this._timer !== null) {
        clearTimeout(this._timer);
        this._timer = null;
      }
      this.destroyed = true;
      if (!this.aborted) emitSafely(this, 'error', error);
      emitSafely(this, 'close');
    });
  }
}

function requestWith(input, options, callback, secure) {
  if (typeof options === 'function') {
    callback = options;
    options = undefined;
  }
  const req = new ClientRequest(input, options, secure);
  if (typeof callback === 'function') req.once('response', callback);
  return req;
}

function request(input, options, callback) {
  return requestWith(input, options, callback, false);
}

function requestSecure(input, options, callback) {
  return requestWith(input, options, callback, true);
}

function get(input, options, callback) {
  const req = request(input, options, callback);
  req.end();
  return req;
}

function getSecure(input, options, callback) {
  const req = requestSecure(input, options, callback);
  req.end();
  return req;
}

function toBuffer(chunk, encoding) {
  if (typeof chunk === 'string') {
    return Buffer.from(chunk, encoding === undefined || encoding === null ? 'utf8' : encoding);
  }
  if (ArrayBuffer.isView(chunk)) {
    return Buffer.from(new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength));
  }
  if (chunk instanceof ArrayBuffer) return Buffer.from(chunk);
  throw invalidArgType('chunk', 'string, Buffer, or Uint8Array', chunk);
}

function dispatch(id, event, payload) {
  if (event === 'request') {
    const server = servers.get(payload.serverId);
    if (server === undefined) {
      // The listener disappeared between accept and dispatch; answer instead of
      // leaving the connection task blocked forever.
      native.respond(id, 500, null, [], new Uint8Array(0), false);
      return;
    }

    const req = new IncomingMessage(payload);
    const res = new ServerResponse(id, payload.keepAlive);
    req.res = res;
    res.req = req;
    pending.set(id, { req, res });
    emitSafely(server, 'request', req, res);
    return;
  }

  if (event === 'drain') {
    const entry = pending.get(id);
    if (entry !== undefined) emitSafely(entry.res, 'drain');
    return;
  }

  if (event === 'close') {
    const server = servers.get(id);
    if (server !== undefined) {
      server._closedFromNative(id);
      return;
    }

    const entry = pending.get(id);
    if (entry !== undefined) {
      pending.delete(id);
      entry.req.destroyed = true;
      entry.req.aborted = true;
      entry.req.readable = false;
      entry.req.socket.destroyed = true;
      entry.req.socket.readable = false;
      entry.res.destroyed = true;
      emitSafely(entry.res, 'close');
      emitSafely(entry.req, 'close');
    }
    return;
  }

  if (event === 'error') {
    const error = nativeError(payload);
    const server = servers.get(id);
    if (server === undefined) {
      queueMicrotask(() => {
        throw error;
      });
      return;
    }
    emitSafely(server, 'error', error);
  }
}

class Server extends EventEmitter {
  constructor(options, requestListener) {
    super();
    this.listening = false;
    this.maxHeadersCount = 2000;
    this.timeout = 0;
    this.keepAliveTimeout = 5000;
    this.headersTimeout = 60000;
    this.requestTimeout = 300000;
    this._options = options === undefined || options === null ? {} : options;
    this._serverId = null;
    this._address = null;
    this._tls = null;
    this._closing = false;
    this._closed = false;
    this._closeCallbacks = [];
    if (typeof requestListener === 'function') this.on('request', requestListener);
  }

  listen(...args) {
    if (this._serverId !== null) {
      const error = new Error('Server is already listening');
      error.code = 'ERR_SERVER_ALREADY_LISTEN';
      throw error;
    }

    let options = {};
    let callback;

    if (args.length > 0 && typeof args[0] === 'function') {
      callback = args[0];
    } else if (args.length > 0 && typeof args[0] === 'object' && args[0] !== null) {
      options = args[0];
      if (typeof args[1] === 'function') callback = args[1];
    } else {
      options = { port: args[0], host: args[1], backlog: args[2] };
      if (typeof args[1] === 'function') {
        options.host = undefined;
        callback = args[1];
      } else if (typeof args[2] === 'function') {
        callback = args[2];
      }
    }

    if (options.port !== undefined && typeof options.port !== 'number') {
      const error = new TypeError(`The "port" argument must be of type number. Received ${typeof options.port}`);
      error.code = 'ERR_INVALID_ARG_TYPE';
      throw error;
    }

    const port = typeof options.port === 'number' && Number.isFinite(options.port)
      ? options.port
      : 0;
    if (!Number.isInteger(port) || port < 0 || port > 65535) {
      const error = new RangeError(`options.port should be >= 0 and < 65536. Received ${options.port}`);
      error.code = 'ERR_SOCKET_BAD_PORT';
      throw error;
    }

    const host = typeof options.host === 'string' ? options.host : '';
    const backlog = typeof options.backlog === 'number' && Number.isFinite(options.backlog)
      ? Math.floor(options.backlog)
      : 511;

    const result = this._tls === null
      ? native.listen(host, port, backlog, dispatch)
      : native.listen(
        host,
        port,
        backlog,
        dispatch,
        this._tls.cert,
        this._tls.key,
        this._tls.ca === undefined ? '' : this._tls.ca,
        this._tls.requestCert === true,
        this._tls.rejectUnauthorized !== false,
      );
    if (result.error !== undefined && result.error !== null) {
      // Node reports bind failures asynchronously on the server.
      queueMicrotask(() => emitSafely(this, 'error', nativeError(result.error)));
      return this;
    }

    this._serverId = result.id;
    this._address = { address: result.address, family: result.family, port: result.port };
    this.listening = true;
    this._closing = false;
    this._closed = false;
    servers.set(result.id, this);

    queueMicrotask(() => {
      if (this._serverId !== result.id) return;
      emitSafely(this, 'listening');
      if (typeof callback === 'function') callback();
    });
    return this;
  }

  address() {
    return this.listening ? this._address : null;
  }

  close(callback) {
    if (typeof callback === 'function') {
      if (this._serverId === null) queueMicrotask(callback);
      else this._closeCallbacks.push(callback);
    }

    if (this._serverId === null) {
      if (!this._closing) queueMicrotask(() => this._finishClose());
      return this;
    }
    if (this._closing) return this;

    this._closing = true;
    this.listening = false;
    native.closeServer(this._serverId);
    return this;
  }

  ref() {
    if (this._serverId !== null) native.serverSetRef(this._serverId, true);
    return this;
  }

  unref() {
    if (this._serverId !== null) native.serverSetRef(this._serverId, false);
    return this;
  }

  _closedFromNative(id) {
    servers.delete(id);
    if (this._serverId !== id) return;
    this._serverId = null;
    this.listening = false;
    this._finishClose();
  }

  _finishClose() {
    if (this._closed) return;
    this._closed = true;
    this._closing = false;
    const callbacks = this._closeCallbacks;
    this._closeCallbacks = [];
    emitSafely(this, 'close');
    for (const callback of callbacks) callback();
  }
}

export function createServer(options, requestListener) {
  if (typeof options === 'function') {
    requestListener = options;
    options = undefined;
  }

  const server = new Server(options);
  if (typeof requestListener === 'function') server.on('request', requestListener);
  return server;
}

export {
  Server,
  IncomingMessage,
  ServerResponse,
  ClientRequest,
  request,
  requestSecure,
  get,
  getSecure,
  STATUS_CODES,
  METHODS,
  MAX_HEADER_SIZE,
};

export default {
  createServer,
  Server,
  IncomingMessage,
  ServerResponse,
  ClientRequest,
  request,
  requestSecure,
  get,
  getSecure,
  STATUS_CODES,
  METHODS,
  fetch,
  Headers,
  Request,
  Response,
};
