// Text coding half of `node:util` (`TextEncoder`/`TextDecoder`). The rest of
// the module lands with Phase 3B.

import * as native from 'node:_encoding';

const UTF8 = 'utf-8';
const UTF16LE = 'utf-16le';
const LATIN1 = 'latin1';

function encodingFromLabel(label) {
  const normalized = String(label).toLowerCase();
  switch (normalized) {
    case 'utf-8':
    case 'utf8':
    case 'unicode-1-1-utf-8':
      return UTF8;
    case 'utf-16le':
    case 'utf-16':
    case 'ucs-2':
    case 'ucs2':
    case 'unicode':
      return UTF16LE;
    case 'latin1':
    case 'binary':
    case 'iso-8859-1':
    case 'windows-1252':
    case 'ascii':
      return LATIN1;
    default:
      break;
  }
  const error = new RangeError(`The encoding label provided ('${label}') is invalid.`);
  error.code = 'ERR_ENCODING_NOT_SUPPORTED';
  throw error;
}

function toView(input) {
  if (input === undefined || input === null) return null;
  if (input instanceof ArrayBuffer) return new Uint8Array(input);
  if (ArrayBuffer.isView(input)) return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
  const error = new TypeError('The "input" argument must be an instance of ArrayBuffer or ArrayBufferView.');
  error.code = 'ERR_INVALID_ARG_TYPE';
  throw error;
}

class TextEncoder {
  get encoding() {
    return UTF8;
  }

  encode(input = '') {
    return native.utf8Encode(String(input));
  }

  encodeInto(source, destination) {
    const text = String(source);
    if (!(destination instanceof Uint8Array)) {
      const error = new TypeError('The "destination" argument must be an instance of Uint8Array.');
      error.code = 'ERR_INVALID_ARG_TYPE';
      throw error;
    }

    let read = 0;
    let written = 0;
    while (read < text.length) {
      const first = text.charCodeAt(read);
      let codepoint = first;
      let units = 1;

      if (first >= 0xd800 && first <= 0xdbff) {
        const second = read + 1 < text.length ? text.charCodeAt(read + 1) : 0;
        if (second >= 0xdc00 && second <= 0xdfff) {
          codepoint = 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00);
          units = 2;
        } else {
          codepoint = 0xfffd;
        }
      } else if (first >= 0xdc00 && first <= 0xdfff) {
        codepoint = 0xfffd;
      }

      const size = codepoint < 0x80 ? 1 : codepoint < 0x800 ? 2 : codepoint < 0x10000 ? 3 : 4;
      // A truncated sequence must never reach the destination buffer.
      if (written + size > destination.length) break;

      if (size === 1) {
        destination[written] = codepoint;
      } else if (size === 2) {
        destination[written] = 0xc0 | (codepoint >> 6);
        destination[written + 1] = 0x80 | (codepoint & 0x3f);
      } else if (size === 3) {
        destination[written] = 0xe0 | (codepoint >> 12);
        destination[written + 1] = 0x80 | ((codepoint >> 6) & 0x3f);
        destination[written + 2] = 0x80 | (codepoint & 0x3f);
      } else {
        destination[written] = 0xf0 | (codepoint >> 18);
        destination[written + 1] = 0x80 | ((codepoint >> 12) & 0x3f);
        destination[written + 2] = 0x80 | ((codepoint >> 6) & 0x3f);
        destination[written + 3] = 0x80 | (codepoint & 0x3f);
      }

      read += units;
      written += size;
    }

    return { read, written };
  }
}

class TextDecoder {
  constructor(label = 'utf-8', options = {}) {
    this.encoding = encodingFromLabel(label);
    this.fatal = !!(options && options.fatal);
    this.ignoreBOM = !!(options && options.ignoreBOM);
  }

  decode(input) {
    const bytes = toView(input);
    if (bytes === null) return '';

    let start = 0;
    if (!this.ignoreBOM) {
      if (this.encoding === UTF8 && bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
        start = 3;
      } else if (this.encoding === UTF16LE && bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
        start = 2;
      }
    }

    const payload = start === 0 ? bytes : bytes.subarray(start);
    if (this.encoding === UTF16LE) return native.utf16leDecode(payload);
    if (this.encoding === LATIN1) return native.latin1Decode(payload);

    if (this.fatal && !native.utf8IsValid(payload)) {
      const error = new TypeError('The encoded data was not valid for encoding utf-8');
      error.code = 'ERR_ENCODING_INVALID_ENCODED_DATA';
      throw error;
    }
    return native.utf8Decode(payload);
  }
}

export { TextEncoder, TextDecoder };
export default { TextEncoder, TextDecoder };
