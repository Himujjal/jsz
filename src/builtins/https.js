// Node.js `node:https` subset: servers and clients over dusty's TLS transport.
//
// `createServer` accepts PEM `cert`/`key` or `pfx`+`passphrase`, and can ask
// for client certificates with `ca`, `requestCert`, and `rejectUnauthorized`.
// `request`/`get` share the streaming client from `node:http` and add `ca`,
// `cert`, `key`, `pfx`, `passphrase`, and `rejectUnauthorized`. PFX bytes are
// converted to PEM by the native PKCS#12 reader before either path.

import {
  Server as HttpServer,
  IncomingMessage,
  ServerResponse,
  STATUS_CODES,
  METHODS,
  requestSecure,
  getSecure,
} from 'node:http';
import { Buffer } from 'node:buffer';
import * as pkcs12 from 'node:_pkcs12';

function toPem(value, name) {
  if (typeof value === 'string') return value;
  if (ArrayBuffer.isView(value)) {
    return Buffer.from(value.buffer, value.byteOffset, value.byteLength).toString('utf8');
  }
  if (value instanceof ArrayBuffer) return Buffer.from(value).toString('utf8');
  const error = new TypeError(`The "${name}" option must be a string or Buffer`);
  error.code = 'ERR_INVALID_ARG_TYPE';
  throw error;
}

function pfxBytes(value) {
  if (typeof value === 'string') return Buffer.from(value, 'latin1');
  if (ArrayBuffer.isView(value)) {
    return Buffer.from(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
  }
  if (value instanceof ArrayBuffer) return Buffer.from(value);
  const error = new TypeError('The "pfx" option must be a string or Buffer');
  error.code = 'ERR_INVALID_ARG_TYPE';
  throw error;
}

function caBundle(value) {
  if (Array.isArray(value)) return value.map((entry) => toPem(entry, 'ca')).join('\n');
  return toPem(value, 'ca');
}

function tlsOptions(options) {
  const opts = options === undefined || options === null ? {} : options;
  const tls = {
    cert: null,
    key: null,
    ca: '',
    requestCert: opts.requestCert === true,
    rejectUnauthorized: opts.rejectUnauthorized !== false,
  };

  if (opts.pfx !== undefined && opts.pfx !== null) {
    const passphrase = opts.passphrase === undefined || opts.passphrase === null
      ? ''
      : String(opts.passphrase);
    const bundle = pkcs12.parse(pfxBytes(opts.pfx), passphrase);
    tls.cert = bundle.cert;
    tls.key = bundle.key;
  } else {
    if (opts.cert === undefined || opts.key === undefined) {
      const error = new TypeError('The "cert" and "key" options are required');
      error.code = 'ERR_MISSING_ARGS';
      throw error;
    }
    tls.cert = toPem(opts.cert, 'cert');
    tls.key = toPem(opts.key, 'key');
  }

  if (opts.ca !== undefined && opts.ca !== null) tls.ca = caBundle(opts.ca);

  if (tls.requestCert && tls.ca.length === 0) {
    const error = new TypeError('The "ca" option is required when "requestCert" is true');
    error.code = 'ERR_MISSING_ARGS';
    throw error;
  }

  return tls;
}

class Server extends HttpServer {
  constructor(options, requestListener) {
    super(options, requestListener);
    this._tls = tlsOptions(options);
  }
}

function createServer(options, requestListener) {
  if (typeof options === 'function') {
    requestListener = options;
    options = undefined;
  }
  const server = new Server(options);
  if (typeof requestListener === 'function') server.on('request', requestListener);
  return server;
}

function request(input, options, callback) {
  return requestSecure(input, options, callback);
}

function get(input, options, callback) {
  return getSecure(input, options, callback);
}

export { Server, createServer, request, get, IncomingMessage, ServerResponse, STATUS_CODES, METHODS };

export default {
  Server,
  createServer,
  request,
  get,
  IncomingMessage,
  ServerResponse,
  STATUS_CODES,
  METHODS,
};
