// WHATWG `URL` / `URLSearchParams` for `node:url`, implemented in plain JS.
// The parser mirrors the basic URL parser state machine; IDNA is best-effort
// (ASCII lowercasing only, no punycode), and every input is encoded as UTF-8.

import { resolve as resolvePath } from 'node:path';
import process from 'node:process';

const kRecord = Symbol('url record');
const kParams = Symbol('search params');
const kList = Symbol('params list');
const kUrl = Symbol('bound url');

const SPECIAL_PORTS = new Map([
  ['ftp', 21],
  ['file', null],
  ['http', 80],
  ['https', 443],
  ['ws', 80],
  ['wss', 443],
]);

const FORM_SAFE = new Set([0x2a, 0x2d, 0x2e, 0x5f]); // * - . _
const FORBIDDEN_HOST = new Set([0x00, 0x09, 0x0a, 0x0d, 0x20, 0x23, 0x2f, 0x3a, 0x3c, 0x3e, 0x3f, 0x40, 0x5b, 0x5c, 0x5d, 0x5e, 0x7c]);
const FORBIDDEN_DOMAIN = new Set([0x00, 0x09, 0x0a, 0x0d, 0x20, 0x23, 0x25, 0x2f, 0x3a, 0x3c, 0x3e, 0x3f, 0x40, 0x5b, 0x5c, 0x5d, 0x5e, 0x7c, 0x7f]);
function charSet(chars) {
  const set = new Set();
  for (const ch of chars) set.add(ch.codePointAt(0));
  return set;
}

const FILE_PATH_SAFE = charSet("!$&'()*+,-./:;=@_");

function asciiSet(extra) {
  const set = new Set();
  for (let cp = 0; cp <= 0x1f; cp += 1) set.add(cp);
  for (const ch of extra) set.add(ch.codePointAt(0));
  return set;
}

const FRAGMENT_SET = asciiSet(' "<>`');
const QUERY_SET = asciiSet(' "#<>');
const SPECIAL_QUERY_SET = asciiSet(' "#<>\'');
const PATH_SET = asciiSet(' "#<>?`{}');
const USERINFO_SET = asciiSet(' "#<>?^`{}/:;=@[\\]|');
const C0_SET = asciiSet('');

function isSpecialScheme(scheme) {
  return SPECIAL_PORTS.has(scheme);
}

function defaultPort(scheme) {
  return SPECIAL_PORTS.get(scheme);
}

function isAsciiAlphaCode(cp) {
  return (cp >= 65 && cp <= 90) || (cp >= 97 && cp <= 122);
}

function isAsciiDigitCode(cp) {
  return cp >= 48 && cp <= 57;
}

function isAsciiAlnumCode(cp) {
  return isAsciiAlphaCode(cp) || isAsciiDigitCode(cp);
}

function isAsciiAlpha(ch) {
  return isAsciiAlphaCode(ch.charCodeAt(0));
}

function isAsciiDigit(ch) {
  return isAsciiDigitCode(ch.charCodeAt(0));
}

function isAsciiAlnum(ch) {
  return isAsciiAlnumCode(ch.charCodeAt(0));
}

function isHexCode(code) {
  return (code >= 48 && code <= 57) || (code >= 65 && code <= 70) || (code >= 97 && code <= 102);
}

function hexByte(byte) {
  const digits = '0123456789ABCDEF';
  return '%' + digits.charAt((byte >> 4) & 0xf) + digits.charAt(byte & 0xf);
}

function encodeCodePoint(cp) {
  if (cp >= 0xd800 && cp <= 0xdfff) cp = 0xfffd;
  if (cp < 0x80) return hexByte(cp);
  if (cp < 0x800) return hexByte(0xc0 | (cp >> 6)) + hexByte(0x80 | (cp & 0x3f));
  if (cp < 0x10000) {
    return hexByte(0xe0 | (cp >> 12)) + hexByte(0x80 | ((cp >> 6) & 0x3f)) + hexByte(0x80 | (cp & 0x3f));
  }
  return hexByte(0xf0 | (cp >> 18)) + hexByte(0x80 | ((cp >> 12) & 0x3f)) +
    hexByte(0x80 | ((cp >> 6) & 0x3f)) + hexByte(0x80 | (cp & 0x3f));
}

function percentEncode(ch, set) {
  const cp = ch.codePointAt(0);
  if (cp <= 0x1f || cp > 0x7e || set.has(cp)) return encodeCodePoint(cp);
  return ch;
}

function encodeWithSet(text, set) {
  let out = '';
  for (const ch of text) out += percentEncode(ch, set);
  return out;
}

function pushUtf8(bytes, cp) {
  if (cp >= 0xd800 && cp <= 0xdfff) cp = 0xfffd;
  if (cp < 0x80) {
    bytes.push(cp);
  } else if (cp < 0x800) {
    bytes.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
  } else if (cp < 0x10000) {
    bytes.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
  } else {
    bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
  }
}

function utf8DecodeBytes(bytes) {
  let out = '';
  let i = 0;
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) i = 3;
  while (i < bytes.length) {
    const first = bytes[i];
    if (first <= 0x7f) {
      out += String.fromCharCode(first);
      i += 1;
      continue;
    }
    let needed = 0;
    let cp = 0;
    let lower = 0x80;
    let upper = 0xbf;
    if (first >= 0xc2 && first <= 0xdf) {
      needed = 1;
      cp = first & 0x1f;
    } else if (first >= 0xe0 && first <= 0xef) {
      needed = 2;
      cp = first & 0x0f;
      if (first === 0xe0) lower = 0xa0;
      if (first === 0xed) upper = 0x9f;
    } else if (first >= 0xf0 && first <= 0xf4) {
      needed = 3;
      cp = first & 0x07;
      if (first === 0xf0) lower = 0x90;
      if (first === 0xf4) upper = 0x8f;
    } else {
      out += '\ufffd';
      i += 1;
      continue;
    }
    let j = i + 1;
    let complete = false;
    while (j < bytes.length && j - i <= needed) {
      const byte = bytes[j];
      const lo = j - i === 1 ? lower : 0x80;
      const hi = j - i === 1 ? upper : 0xbf;
      if (byte < lo || byte > hi) break;
      cp = (cp << 6) | (byte & 0x3f);
      j += 1;
      if (j - i === needed + 1) complete = true;
    }
    if (complete) {
      out += String.fromCodePoint(cp);
      i = j;
    } else {
      out += '\ufffd';
      i = j > i ? j : i + 1;
    }
  }
  return out;
}

function percentDecode(text) {
  const bytes = [];
  for (let i = 0; i < text.length; i += 1) {
    const code = text.charCodeAt(i);
    if (code === 0x25 && i + 2 < text.length && isHexCode(text.charCodeAt(i + 1)) && isHexCode(text.charCodeAt(i + 2))) {
      bytes.push(parseInt(text.slice(i + 1, i + 3), 16));
      i += 2;
      continue;
    }
    const cp = text.codePointAt(i);
    pushUtf8(bytes, cp);
    if (cp > 0xffff) i += 1;
  }
  return utf8DecodeBytes(bytes);
}

function formEncode(text) {
  let out = '';
  for (const ch of text) {
    const cp = ch.codePointAt(0);
    if (cp === 0x20) out += '+';
    else if (cp < 0x80 && (isAsciiAlnumCode(cp) || FORM_SAFE.has(cp))) out += ch;
    else out += encodeCodePoint(cp);
  }
  return out;
}

function formDecode(text) {
  return percentDecode(text.split('+').join(' '));
}

function stripInput(input, trim) {
  let start = 0;
  let end = input.length;
  if (trim) {
    while (start < end && input.charCodeAt(start) <= 0x20) start += 1;
    while (end > start && input.charCodeAt(end - 1) <= 0x20) end -= 1;
  }
  let out = '';
  for (let i = start; i < end; i += 1) {
    const code = input.charCodeAt(i);
    if (code === 0x09 || code === 0x0a || code === 0x0d) continue;
    out += input[i];
  }
  return out;
}

function newRecord() {
  return {
    scheme: '',
    username: '',
    password: '',
    host: null,
    port: null,
    path: [],
    opaquePath: null,
    query: null,
    fragment: null,
  };
}

function findScheme(cps) {
  if (cps.length === 0 || !isAsciiAlpha(cps[0])) return -1;
  for (let i = 1; i < cps.length; i += 1) {
    const ch = cps[i];
    if (ch === ':') return i;
    if (!(isAsciiAlnum(ch) || ch === '+' || ch === '-' || ch === '.')) return -1;
  }
  return -1;
}

function isDoubleDotSegment(segment) {
  const s = segment.toLowerCase();
  return s === '..' || s === '.%2e' || s === '%2e.' || s === '%2e%2e';
}

function isSingleDotSegment(segment) {
  const s = segment.toLowerCase();
  return s === '.' || s === '%2e';
}

function isWindowsDriveSegment(segment) {
  return segment.length === 2 && isAsciiAlpha(segment.charAt(0)) &&
    (segment.charAt(1) === ':' || segment.charAt(1) === '|');
}

function startsWithWindowsDriveLetter(cps, index) {
  if (index + 1 >= cps.length) return false;
  if (!isAsciiAlpha(cps[index])) return false;
  const second = cps[index + 1];
  if (second !== ':' && second !== '|') return false;
  if (index + 2 === cps.length) return true;
  return cps[index + 2] === '/' || cps[index + 2] === '\\';
}

function isNormalizedWindowsDrive(segment) {
  return typeof segment === 'string' && /^[A-Za-z]:$/.test(segment);
}

function shortenPath(rec) {
  if (rec.path.length > 0) rec.path.pop();
}

function parseIPv4Number(part) {
  if (/^0[xX][0-9a-fA-F]+$/.test(part)) return parseInt(part.slice(2), 16);
  if (/^0[0-7]+$/.test(part)) return parseInt(part, 8);
  if (/^[0-9]+$/.test(part)) return parseInt(part, 10);
  return null;
}

function parseIPv4(text) {
  let input = text;
  if (input.charAt(input.length - 1) === '.') input = input.slice(0, -1);
  const parts = input.split('.');
  if (parts.length === 0 || parts.length > 4) return null;
  const numbers = [];
  for (const part of parts) {
    if (part === '') return null;
    const value = parseIPv4Number(part);
    if (value === null) return null;
    numbers.push(value);
  }
  for (let i = 0; i < numbers.length - 1; i += 1) {
    if (numbers[i] > 255) return null;
  }
  const last = numbers[numbers.length - 1];
  if (last >= Math.pow(256, 5 - numbers.length)) return null;
  let value = last;
  for (let i = 0; i < numbers.length - 1; i += 1) value += numbers[i] * Math.pow(256, 3 - i);
  value = value >>> 0;
  return ((value >>> 24) & 0xff) + '.' + ((value >>> 16) & 0xff) + '.' +
    ((value >>> 8) & 0xff) + '.' + (value & 0xff);
}

function parseIPv4Strict(text) {
  const parts = text.split('.');
  if (parts.length !== 4) return null;
  let value = 0;
  for (const part of parts) {
    if (part === '') return null;
    const number = parseIPv4Number(part);
    if (number === null || number > 255) return null;
    value = (value * 256) + number;
  }
  return value >>> 0;
}

function parseIPv6Pieces(text) {
  if (text === '') return [];
  const pieces = text.split(':');
  const out = [];
  for (let i = 0; i < pieces.length; i += 1) {
    const piece = pieces[i];
    if (piece === '') return null;
    if (i === pieces.length - 1 && piece.indexOf('.') !== -1) {
      const value = parseIPv4Strict(piece);
      if (value === null) return null;
      out.push((value >>> 16) & 0xffff, value & 0xffff);
    } else {
      if (!/^[0-9a-fA-F]{1,4}$/.test(piece)) return null;
      out.push(parseInt(piece, 16));
    }
  }
  return out;
}

function serializeIPv6(pieces) {
  let bestStart = -1;
  let bestLength = 1;
  let i = 0;
  while (i < 8) {
    if (pieces[i] === 0) {
      let j = i;
      while (j < 8 && pieces[j] === 0) j += 1;
      if (j - i > bestLength) {
        bestStart = i;
        bestLength = j - i;
      }
      i = j;
    } else {
      i += 1;
    }
  }
  const hex = (value) => value.toString(16);
  if (bestStart === -1) return '[' + pieces.map(hex).join(':') + ']';
  const before = pieces.slice(0, bestStart).map(hex).join(':');
  const after = pieces.slice(bestStart + bestLength).map(hex).join(':');
  return '[' + before + '::' + after + ']';
}

function parseIPv6(text) {
  if (text === '') return null;
  const first = text.indexOf('::');
  if (first !== -1 && text.indexOf('::', first + 2) !== -1) return null;
  if (first === -1) {
    const pieces = parseIPv6Pieces(text);
    if (pieces === null || pieces.length !== 8) return null;
    return serializeIPv6(pieces);
  }
  const left = parseIPv6Pieces(text.slice(0, first));
  const right = parseIPv6Pieces(text.slice(first + 2));
  if (left === null || right === null) return null;
  if (left.length + right.length > 7) return null;
  const zeros = [];
  for (let i = 0; i < 8 - left.length - right.length; i += 1) zeros.push(0);
  return serializeIPv6(left.concat(zeros, right));
}

function endsInNumber(domain) {
  const parts = domain.split('.');
  if (parts.length > 0 && parts[parts.length - 1] === '') parts.pop();
  if (parts.length === 0) return false;
  const last = parts[parts.length - 1];
  return /^[0-9]+$/.test(last) || /^0[xX][0-9a-fA-F]*$/.test(last);
}

function parseHost(text, opaque) {
  if (text.charAt(0) === '[') {
    if (text.charAt(text.length - 1) !== ']') return null;
    return parseIPv6(text.slice(1, -1));
  }
  if (opaque) {
    for (const ch of text) {
      if (FORBIDDEN_HOST.has(ch.codePointAt(0))) return null;
    }
    return text;
  }
  const decoded = percentDecode(text).toLowerCase();
  if (decoded === '') return null;
  for (const ch of decoded) {
    if (FORBIDDEN_DOMAIN.has(ch.codePointAt(0))) return null;
  }
  if (endsInNumber(decoded)) return parseIPv4(decoded);
  return decoded;
}

function setQueryAndRest(rec, cps, index, special) {
  let hash = -1;
  for (let i = index + 1; i < cps.length; i += 1) {
    if (cps[i] === '#') {
      hash = i;
      break;
    }
  }
  const end = hash === -1 ? cps.length : hash;
  rec.query = encodeWithSet(cps.slice(index + 1, end).join(''), special ? SPECIAL_QUERY_SET : QUERY_SET);
  if (hash !== -1) rec.fragment = encodeWithSet(cps.slice(hash + 1).join(''), FRAGMENT_SET);
  return rec;
}

function parsePathInto(rec, cps, start, special, override) {
  let buffer = '';
  for (let i = start; i <= cps.length; i += 1) {
    const ch = i < cps.length ? cps[i] : null;
    const isSeparator = ch === null || ch === '/' || (special && ch === '\\') ||
      (!override && (ch === '?' || ch === '#'));

    if (!isSeparator) {
      buffer += percentEncode(ch, PATH_SET);
      continue;
    }

    if (isDoubleDotSegment(buffer)) {
      shortenPath(rec);
      if (ch !== '/' && !(special && ch === '\\')) rec.path.push('');
    } else if (isSingleDotSegment(buffer)) {
      if (ch !== '/' && !(special && ch === '\\')) rec.path.push('');
    } else {
      let segment = buffer;
      if (rec.scheme === 'file' && rec.path.length === 0 && isWindowsDriveSegment(segment)) {
        segment = segment.charAt(0) + ':';
      }
      rec.path.push(segment);
    }
    buffer = '';

    if (override) continue;
    if (ch === '?') return setQueryAndRest(rec, cps, i, special);
    if (ch === '#') {
      rec.fragment = encodeWithSet(cps.slice(i + 1).join(''), FRAGMENT_SET);
      return rec;
    }
    if (ch === null) return rec;
  }
  return rec;
}

function parsePathStart(rec, cps, index, special) {
  let i = index;
  if (special) {
    if (i < cps.length && (cps[i] === '/' || cps[i] === '\\')) i += 1;
    return parsePathInto(rec, cps, i, true, false);
  }
  if (i < cps.length && cps[i] === '?') return setQueryAndRest(rec, cps, i, false);
  if (i < cps.length && cps[i] === '#') {
    rec.fragment = encodeWithSet(cps.slice(i + 1).join(''), FRAGMENT_SET);
    return rec;
  }
  if (i < cps.length && cps[i] === '/') {
    return parsePathInto(rec, cps, i + 1, false, false);
  }
  if (i < cps.length) return parsePathInto(rec, cps, i, false, false);
  return rec;
}

function parseOpaquePath(rec, cps, start) {
  let path = '';
  for (let i = start; i < cps.length; i += 1) {
    const ch = cps[i];
    if (ch === '?') {
      rec.opaquePath = path;
      return setQueryAndRest(rec, cps, i, isSpecialScheme(rec.scheme));
    }
    if (ch === '#') {
      rec.opaquePath = path;
      rec.fragment = encodeWithSet(cps.slice(i + 1).join(''), FRAGMENT_SET);
      return rec;
    }
    path += percentEncode(ch, C0_SET);
  }
  rec.opaquePath = path;
  return rec;
}

function parseAuthority(rec, cps, start, special) {
  let i = start;
  let buffer = '';
  let atSignSeen = false;
  let passwordTokenSeen = false;

  while (i < cps.length) {
    const ch = cps[i];
    if (ch === '@') {
      if (atSignSeen) buffer = '%40' + buffer;
      for (const piece of buffer) {
        if (piece === ':' && !passwordTokenSeen) {
          passwordTokenSeen = true;
          continue;
        }
        const encoded = percentEncode(piece, USERINFO_SET);
        if (passwordTokenSeen) rec.password += encoded;
        else rec.username += encoded;
      }
      buffer = '';
      atSignSeen = true;
      i += 1;
      continue;
    }
    if (ch === '/' || ch === '?' || ch === '#' || (special && ch === '\\')) break;
    buffer += ch;
    i += 1;
  }
  if (atSignSeen && buffer === '') return null;

  let hostText = buffer;
  let portText = null;
  if (buffer.charAt(0) === '[') {
    const close = buffer.indexOf(']');
    if (close === -1) return null;
    hostText = buffer.slice(0, close + 1);
    const rest = buffer.slice(close + 1);
    if (rest !== '') {
      if (rest.charAt(0) !== ':') return null;
      portText = rest.slice(1);
    }
  } else {
    const colon = buffer.indexOf(':');
    if (colon !== -1) {
      hostText = buffer.slice(0, colon);
      portText = buffer.slice(colon + 1);
    }
  }

  if (hostText === '') {
    if (special) return null;
    rec.host = '';
  } else {
    const host = parseHost(hostText, !special);
    if (host === null) return null;
    rec.host = host;
  }

  if (portText !== null && portText !== '') {
    if (!/^[0-9]+$/.test(portText)) return null;
    const port = parseInt(portText, 10);
    if (port > 65535) return null;
    const def = defaultPort(rec.scheme);
    rec.port = def !== undefined && port === def ? null : port;
  }

  return parsePathStart(rec, cps, i, special);
}

function copyBase(rec, base) {
  rec.scheme = base.scheme;
  rec.username = base.username;
  rec.password = base.password;
  rec.host = base.host;
  rec.port = base.port;
  rec.path = base.path.slice();
  rec.query = base.query;
}

function parseRelativeInto(rec, cps, start, base) {
  if (base === null) return null;
  const special = isSpecialScheme(base.scheme);
  rec.scheme = base.scheme;

  if (base.opaquePath !== null) {
    if (start < cps.length && cps[start] === '#') {
      copyBase(rec, base);
      rec.opaquePath = base.opaquePath;
      rec.fragment = encodeWithSet(cps.slice(start + 1).join(''), FRAGMENT_SET);
      return rec;
    }
    return null;
  }

  if (start < cps.length) {
    const ch = cps[start];
    if (ch === '/' || (special && ch === '\\')) {
      const second = start + 1 < cps.length ? cps[start + 1] : null;
      if (second !== null && (second === '/' || (special && second === '\\'))) {
        let i = start + 2;
        if (special) {
          while (i < cps.length && (cps[i] === '/' || cps[i] === '\\')) i += 1;
        }
        return parseAuthority(rec, cps, i, special);
      }
      rec.username = base.username;
      rec.password = base.password;
      rec.host = base.host;
      rec.port = base.port;
      rec.path = [];
      return parsePathInto(rec, cps, start + 1, special, false);
    }
    if (ch === '?') {
      copyBase(rec, base);
      return setQueryAndRest(rec, cps, start, special);
    }
    if (ch === '#') {
      copyBase(rec, base);
      rec.fragment = encodeWithSet(cps.slice(start + 1).join(''), FRAGMENT_SET);
      return rec;
    }
  }

  copyBase(rec, base);
  if (start === cps.length) return rec;
  rec.query = null;
  shortenPath(rec);
  return parsePathInto(rec, cps, start, special, false);
}

function parseFileHost(rec, cps, start, base) {
  let i = start;
  const bufferStart = i;
  while (i < cps.length) {
    const ch = cps[i];
    if (ch === '/' || ch === '\\' || ch === '?' || ch === '#') break;
    i += 1;
  }
  const buffer = cps.slice(bufferStart, i).join('');

  if (isWindowsDriveSegment(buffer)) {
    rec.host = '';
    rec.path = [];
    return parsePathInto(rec, cps, bufferStart, true, false);
  }

  if (buffer === '') {
    rec.host = '';
  } else {
    const host = parseHost(buffer, false);
    if (host === null) return null;
    rec.host = host === 'localhost' ? '' : host;
  }

  if (i < cps.length && (cps[i] === '/' || cps[i] === '\\')) i += 1;
  return parsePathInto(rec, cps, i, true, false);
}

function parseFile(cps, base) {
  const rec = newRecord();
  rec.scheme = 'file';
  rec.host = '';

  if (cps.length > 0 && (cps[0] === '/' || cps[0] === '\\')) {
    if (cps.length > 1 && (cps[1] === '/' || cps[1] === '\\')) {
      return parseFileHost(rec, cps, 2, base);
    }
    const baseIsFile = base !== null && base.scheme === 'file';
    if (baseIsFile) {
      rec.host = base.host;
      if (!startsWithWindowsDriveLetter(cps, 1) && isNormalizedWindowsDrive(base.path[0])) {
        rec.path.push(base.path[0]);
      }
    }
    return parsePathInto(rec, cps, 1, true, false);
  }

  const baseIsFile = base !== null && base.scheme === 'file';
  if (baseIsFile) {
    if (cps.length === 0) {
      rec.host = base.host;
      rec.path = base.path.slice();
      rec.query = base.query;
      return rec;
    }
    const ch = cps[0];
    if (ch === '?') {
      rec.host = base.host;
      rec.path = base.path.slice();
      return setQueryAndRest(rec, cps, 0, true);
    }
    if (ch === '#') {
      rec.host = base.host;
      rec.path = base.path.slice();
      rec.query = base.query;
      rec.fragment = encodeWithSet(cps.slice(1).join(''), FRAGMENT_SET);
      return rec;
    }
    rec.host = base.host;
    rec.path = base.path.slice();
    if (startsWithWindowsDriveLetter(cps, 0)) rec.path = [];
    else shortenPath(rec);
  }

  return parsePathInto(rec, cps, 0, true, false);
}

function parseUrl(input, base) {
  const text = stripInput(String(input), true);
  const cps = Array.from(text);
  const colon = findScheme(cps);
  if (colon === -1) {
    if (base !== null && base.scheme === 'file') return parseFile(cps, base);
    return parseRelativeInto(newRecord(), cps, 0, base);
  }

  const scheme = cps.slice(0, colon).join('').toLowerCase();
  const rest = cps.slice(colon + 1);

  if (scheme === 'file') return parseFile(rest, base);

  const rec = newRecord();
  rec.scheme = scheme;

  if (isSpecialScheme(scheme)) {
    if (base !== null && base.scheme === scheme) return parseRelativeInto(rec, rest, 0, base);
    let i = 0;
    while (i < rest.length && (rest[i] === '/' || rest[i] === '\\')) i += 1;
    return parseAuthority(rec, rest, i, true);
  }

  if (base !== null && base.scheme === scheme && base.opaquePath === null) {
    return parseRelativeInto(rec, rest, 0, base);
  }

  if (rest.length >= 2 && rest[0] === '/' && rest[1] === '/') {
    return parseAuthority(rec, rest, 2, false);
  }
  if (rest.length >= 1 && rest[0] === '/') {
    return parsePathInto(rec, rest, 1, false, false);
  }
  return parseOpaquePath(rec, rest, 0);
}

function serializePath(rec) {
  if (rec.opaquePath !== null) return rec.opaquePath;
  let out = '';
  for (const segment of rec.path) out += '/' + segment;
  return out;
}

function serialize(rec) {
  let out = rec.scheme + ':';
  if (rec.host !== null) {
    out += '//';
    if (rec.username !== '' || rec.password !== '') {
      out += rec.username;
      if (rec.password !== '') out += ':' + rec.password;
      out += '@';
    }
    out += rec.host;
    if (rec.port !== null) out += ':' + rec.port;
  }
  if (rec.host === null && rec.opaquePath === null && rec.path.length > 1 && rec.path[0] === '') {
    out += '/.';
  }
  out += serializePath(rec);
  if (rec.query !== null) out += '?' + rec.query;
  if (rec.fragment !== null) out += '#' + rec.fragment;
  return out;
}

function originOf(rec) {
  const scheme = rec.scheme;
  if (scheme === 'blob') {
    const inner = rec.opaquePath === null ? null : parseUrl(rec.opaquePath, null);
    return inner === null ? 'null' : originOf(inner);
  }
  if (scheme !== 'http' && scheme !== 'https' && scheme !== 'ws' && scheme !== 'wss' && scheme !== 'ftp') {
    return 'null';
  }
  if (rec.host === null || rec.host === '') return 'null';
  return scheme + '://' + rec.host + (rec.port === null ? '' : ':' + rec.port);
}

function invalidUrl(input) {
  const error = new TypeError('Invalid URL');
  error.code = 'ERR_INVALID_URL';
  error.input = input;
  return error;
}

function invalidArgType(name, expected, value) {
  const error = new TypeError(`The "${name}" argument must be of type ${expected}. Received ${typeof value}`);
  error.code = 'ERR_INVALID_ARG_TYPE';
  return error;
}

function parseFormPairs(text) {
  const pairs = [];
  const parts = text.split('&');
  for (const part of parts) {
    if (part === '') continue;
    const index = part.indexOf('=');
    if (index === -1) pairs.push([formDecode(part), '']);
    else pairs.push([formDecode(part.slice(0, index)), formDecode(part.slice(index + 1))]);
  }
  return pairs;
}

function invalidTuple() {
  const error = new TypeError('Each query pair must be an iterable [name, value] tuple');
  error.code = 'ERR_INVALID_TUPLE';
  return error;
}

function serializeForm(list) {
  let out = '';
  for (let i = 0; i < list.length; i += 1) {
    if (i > 0) out += '&';
    out += formEncode(list[i][0]) + '=' + formEncode(list[i][1]);
  }
  return out;
}

function createIterator(list, kind) {
  let index = 0;
  const iterator = {
    next() {
      if (index >= list.length) return { value: undefined, done: true };
      const pair = list[index];
      index += 1;
      if (kind === 'key') return { value: pair[0], done: false };
      if (kind === 'value') return { value: pair[1], done: false };
      return { value: [pair[0], pair[1]], done: false };
    },
  };
  iterator[Symbol.iterator] = function () {
    return this;
  };
  iterator[Symbol.toStringTag] = 'URLSearchParams Iterator';
  return iterator;
}

class URLSearchParams {
  constructor(init) {
    this[kList] = [];
    this[kUrl] = null;

    if (init === undefined || init === null) return;

    if (typeof init === 'object') {
      const iterator = init[Symbol.iterator];
      if (typeof iterator === 'function') {
        for (const pair of init) {
          if (pair === null || typeof pair !== 'object') throw invalidTuple();
          const tuple = Array.from(pair);
          if (tuple.length !== 2) throw invalidTuple();
          this[kList].push([String(tuple[0]), String(tuple[1])]);
        }
        return;
      }
      const keys = Object.keys(init);
      for (const key of keys) this[kList].push([key, String(init[key])]);
      return;
    }

    let text = String(init);
    if (text.charAt(0) === '?') text = text.slice(1);
    this[kList] = parseFormPairs(text);
  }

  get size() {
    return this[kList].length;
  }

  append(name, value) {
    this[kList].push([String(name), String(value)]);
    updateFromParams(this);
  }

  delete(name, value) {
    const key = String(name);
    const expected = value === undefined ? undefined : String(value);
    const list = this[kList];
    for (let i = list.length - 1; i >= 0; i -= 1) {
      if (list[i][0] === key && (expected === undefined || list[i][1] === expected)) {
        list.splice(i, 1);
      }
    }
    updateFromParams(this);
  }

  get(name) {
    const key = String(name);
    const list = this[kList];
    for (let i = 0; i < list.length; i += 1) {
      if (list[i][0] === key) return list[i][1];
    }
    return null;
  }

  getAll(name) {
    const key = String(name);
    const list = this[kList];
    const out = [];
    for (let i = 0; i < list.length; i += 1) {
      if (list[i][0] === key) out.push(list[i][1]);
    }
    return out;
  }

  has(name, value) {
    const key = String(name);
    const expected = value === undefined ? undefined : String(value);
    const list = this[kList];
    for (let i = 0; i < list.length; i += 1) {
      if (list[i][0] === key && (expected === undefined || list[i][1] === expected)) return true;
    }
    return false;
  }

  set(name, value) {
    const key = String(name);
    const next = String(value);
    const list = this[kList];
    let found = false;
    for (let i = 0; i < list.length; i += 1) {
      if (list[i][0] !== key) continue;
      if (!found) {
        list[i][1] = next;
        found = true;
      } else {
        list.splice(i, 1);
        i -= 1;
      }
    }
    if (!found) list.push([key, next]);
    updateFromParams(this);
  }

  sort() {
    this[kList].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
    updateFromParams(this);
  }

  forEach(callback, thisArg) {
    if (typeof callback !== 'function') throw invalidArgType('callback', 'function', callback);
    const list = this[kList];
    for (let i = 0; i < list.length; i += 1) {
      callback.call(thisArg, list[i][1], list[i][0], this);
    }
  }

  keys() {
    return createIterator(this[kList], 'key');
  }

  values() {
    return createIterator(this[kList], 'value');
  }

  entries() {
    return createIterator(this[kList], 'entry');
  }

  toString() {
    return serializeForm(this[kList]);
  }

  [Symbol.iterator]() {
    return this.entries();
  }
}

URLSearchParams.prototype[Symbol.toStringTag] = 'URLSearchParams';

function updateFromParams(params) {
  const url = params[kUrl];
  if (url === null) return;
  const rec = url[kRecord];
  if (params[kList].length === 0) rec.query = null;
  else rec.query = serializeForm(params[kList]);
}

function syncParams(url) {
  const params = url[kParams];
  if (params === null) return;
  const query = url[kRecord].query;
  params[kList] = query === null ? [] : parseFormPairs(query);
}

function cannotHaveCredentials(rec) {
  return rec.host === null || rec.host === '' || rec.scheme === 'file';
}

function containsWindowsDrive(path) {
  for (const segment of path) {
    if (isNormalizedWindowsDrive(segment)) return true;
  }
  return false;
}

function setHostValue(rec, value, hostnameOnly) {
  if (rec.opaquePath !== null) return;
  const text = stripInput(String(value), false);
  if (text === '') {
    if (rec.scheme === 'file' || !isSpecialScheme(rec.scheme)) rec.host = '';
    return;
  }

  let hostText = text;
  let portText = null;
  if (text.charAt(0) === '[') {
    const close = text.indexOf(']');
    if (close === -1) return;
    hostText = text.slice(0, close + 1);
    const rest = text.slice(close + 1);
    if (rest !== '') {
      if (hostnameOnly) return;
      if (rest.charAt(0) !== ':') return;
      portText = rest.slice(1);
    }
  } else {
    const colon = text.indexOf(':');
    if (colon !== -1) {
      if (hostnameOnly) return;
      hostText = text.slice(0, colon);
      portText = text.slice(colon + 1);
    }
  }

  if (rec.scheme === 'file' && portText !== null) return;

  if (hostText === '') {
    if (isSpecialScheme(rec.scheme) && rec.scheme !== 'file') return;
    rec.host = '';
    return;
  }

  const host = parseHost(hostText, !isSpecialScheme(rec.scheme));
  if (host === null) return;
  rec.host = rec.scheme === 'file' && host === 'localhost' ? '' : host;

  if (portText !== null) {
    let number = 0;
    let seen = false;
    for (const ch of portText) {
      if (!isAsciiDigit(ch)) break;
      seen = true;
      number = (number * 10) + (ch.charCodeAt(0) - 48);
      if (number > 65535) break;
    }
    if (seen && number <= 65535) {
      const def = defaultPort(rec.scheme);
      rec.port = def !== undefined && number === def ? null : number;
    }
  }
}

function setPortValue(rec, value) {
  if (rec.host === null || rec.scheme === 'file') return;
  const text = stripInput(String(value), false);
  if (text === '') {
    rec.port = null;
    return;
  }
  if (!/^[0-9]+$/.test(text)) return;
  const port = parseInt(text, 10);
  if (port > 65535) return;
  const def = defaultPort(rec.scheme);
  rec.port = def !== undefined && port === def ? null : port;
}

function setCredentials(rec, value, password) {
  if (cannotHaveCredentials(rec)) return;
  const text = encodeWithSet(stripInput(String(value), false), USERINFO_SET);
  if (password) rec.password = text;
  else rec.username = text;
}

function setPathnameValue(rec, value) {
  if (rec.opaquePath !== null) return;
  const cps = Array.from(stripInput(String(value), false));
  const special = isSpecialScheme(rec.scheme);
  rec.path = [];
  if (cps.length === 0) {
    if (special || rec.host === null) rec.path.push('');
    return;
  }
  let i = 0;
  if (cps[0] === '/' || (special && cps[0] === '\\')) i = 1;
  parsePathInto(rec, cps, i, special, true);
}

function setSearchValue(rec, value) {
  let text = stripInput(String(value), false);
  if (text === '') {
    rec.query = null;
    return;
  }
  if (text.charAt(0) === '?') text = text.slice(1);
  rec.query = encodeWithSet(text, isSpecialScheme(rec.scheme) ? SPECIAL_QUERY_SET : QUERY_SET);
}

function setHashValue(rec, value) {
  const text = stripInput(String(value), false);
  if (text === '') {
    rec.fragment = null;
    return;
  }
  const fragment = text.charAt(0) === '#' ? text.slice(1) : text;
  rec.fragment = encodeWithSet(fragment, FRAGMENT_SET);
}

function setProtocolValue(rec, value) {
  const text = stripInput(String(value), false);
  const colon = text.indexOf(':');
  const candidate = (colon === -1 ? text : text.slice(0, colon)).toLowerCase();
  if (!/^[a-z][a-z0-9+.-]*$/.test(candidate)) return;
  const current = rec.scheme;
  if (candidate === current) return;
  if (isSpecialScheme(current) !== isSpecialScheme(candidate)) return;
  if (candidate === 'file') {
    if (rec.username !== '' || rec.password !== '' || rec.port !== null) return;
  } else if (current === 'file') {
    if (rec.host === '' || rec.query !== null || rec.username !== '' || rec.password !== '' ||
        containsWindowsDrive(rec.path)) return;
  }
  rec.scheme = candidate;
}

class URL {
  constructor(input, base) {
    if (arguments.length === 0) {
      const error = new TypeError('The "url" argument must be specified');
      error.code = 'ERR_MISSING_ARGS';
      throw error;
    }
    const inputText = String(input);
    let baseRecord = null;
    if (base !== undefined) {
      baseRecord = parseUrl(String(base), null);
      if (baseRecord === null) throw invalidUrl(inputText);
    }
    const record = parseUrl(inputText, baseRecord);
    if (record === null) throw invalidUrl(inputText);
    this[kRecord] = record;
    this[kParams] = null;
  }

  static canParse(input, base) {
    if (arguments.length === 0) return false;
    try {
      return new URL(input, base) !== null;
    } catch {
      return false;
    }
  }

  static parse(input, base) {
    if (arguments.length === 0) return null;
    try {
      return new URL(input, base);
    } catch {
      return null;
    }
  }

  get href() {
    return serialize(this[kRecord]);
  }

  set href(value) {
    const text = String(value);
    const record = parseUrl(text, null);
    if (record === null) throw invalidUrl(text);
    this[kRecord] = record;
    syncParams(this);
  }

  get origin() {
    return originOf(this[kRecord]);
  }

  get protocol() {
    return this[kRecord].scheme + ':';
  }

  set protocol(value) {
    setProtocolValue(this[kRecord], value);
  }

  get username() {
    return this[kRecord].username;
  }

  set username(value) {
    setCredentials(this[kRecord], value, false);
  }

  get password() {
    return this[kRecord].password;
  }

  set password(value) {
    setCredentials(this[kRecord], value, true);
  }

  get host() {
    const rec = this[kRecord];
    if (rec.host === null) return '';
    return rec.host + (rec.port === null ? '' : ':' + rec.port);
  }

  set host(value) {
    setHostValue(this[kRecord], value, false);
  }

  get hostname() {
    const rec = this[kRecord];
    return rec.host === null ? '' : rec.host;
  }

  set hostname(value) {
    setHostValue(this[kRecord], value, true);
  }

  get port() {
    const rec = this[kRecord];
    return rec.port === null ? '' : String(rec.port);
  }

  set port(value) {
    setPortValue(this[kRecord], value);
  }

  get pathname() {
    return serializePath(this[kRecord]);
  }

  set pathname(value) {
    setPathnameValue(this[kRecord], value);
  }

  get search() {
    const rec = this[kRecord];
    if (rec.query === null || rec.query === '') return '';
    return '?' + rec.query;
  }

  set search(value) {
    setSearchValue(this[kRecord], value);
    syncParams(this);
  }

  get searchParams() {
    if (this[kParams] === null) {
      const params = new URLSearchParams();
      params[kUrl] = this;
      this[kParams] = params;
      syncParams(this);
    }
    return this[kParams];
  }

  get hash() {
    const rec = this[kRecord];
    return rec.fragment === null || rec.fragment === '' ? '' : '#' + rec.fragment;
  }

  set hash(value) {
    setHashValue(this[kRecord], value);
  }

  toString() {
    return this.href;
  }

  toJSON() {
    return this.href;
  }
}

URL.prototype[Symbol.toStringTag] = 'URL';

function encodeFilePath(path) {
  let out = '';
  for (const ch of path) {
    const cp = ch.codePointAt(0);
    if (cp < 0x80 && (isAsciiAlnumCode(cp) || FILE_PATH_SAFE.has(cp))) out += ch;
    else out += encodeCodePoint(cp);
  }
  return out;
}

function pathToFileURL(path) {
  if (typeof path !== 'string') throw invalidArgType('path', 'string', path);
  const resolved = resolvePath(process.cwd(), path);
  return new URL('file://' + encodeFilePath(resolved));
}

function invalidFileUrlScheme() {
  const error = new TypeError('The URL must be of scheme file');
  error.code = 'ERR_INVALID_URL_SCHEME';
  return error;
}

function invalidFileUrlHost() {
  const error = new TypeError(`File URL host must be "localhost" or empty on ${process.platform}`);
  error.code = 'ERR_INVALID_FILE_URL_HOST';
  return error;
}

function invalidFileUrlPath(reason) {
  const error = new TypeError(`File URL path must not include ${reason}`);
  error.code = 'ERR_INVALID_FILE_URL_PATH';
  return error;
}

function fileURLToPath(url) {
  let value = url;
  if (typeof value === 'string') value = new URL(value);
  else if (!(value instanceof URL) && !(value !== null && typeof value === 'object' && typeof value.href === 'string')) {
    throw invalidArgType('path', 'string or URL', value);
  }

  if (value.protocol !== 'file:') throw invalidFileUrlScheme();
  if (value.host !== '') throw invalidFileUrlHost();

  const pathname = value.pathname;
  if (/%2f/i.test(pathname)) throw invalidFileUrlPath('encoded / characters');
  if (/%00/i.test(pathname)) throw invalidFileUrlPath('encoded null characters');
  return percentDecode(pathname);
}

export { URL, URLSearchParams, pathToFileURL, fileURLToPath };

export default { URL, URLSearchParams, pathToFileURL, fileURLToPath };
