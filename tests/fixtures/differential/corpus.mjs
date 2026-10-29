// Differential corpus: deterministic lines compared byte-for-byte against a
// real `node` binary by tests/zig/differential_test.zig.
//
// Rules for cases added here:
// - no time, env, cwd, network, or filesystem inputs
// - print one stable `<label>=<value>` line per case
// - prefer JSON.stringify when the raw string form is ambiguous

import path from 'node:path';
import { Buffer } from 'node:buffer';
import { URL, URLSearchParams } from 'node:url';
import util from 'node:util';

const out = (label, value) => console.log(`${label}=${JSON.stringify(value)}`);
const show = (label, value) => console.log(`${label}=${value}`);

// ---------------------------------------------------------------- node:path

out('path-posix-join', path.posix.join('/a', 'b', '..', 'c', ''));
out('path-posix-join-empty', path.posix.join());
out('path-posix-join-root', path.posix.join('/', 'a', '../..', 'b'));
out('path-posix-normalize', path.posix.normalize('/a//b/./../c/'));
out('path-posix-normalize-rel', path.posix.normalize('a/../../b'));
out('path-posix-directory', path.posix.dirname('/a/b/c.txt'));
out('path-posix-directory-rel', path.posix.dirname('a/b/c.txt'));
out('path-posix-basename', path.posix.basename('/a/b/c.txt'));
out('path-posix-basename-ext', path.posix.basename('/a/b/c.txt', '.txt'));
out('path-posix-extname', path.posix.extname('/a/b/c.tar.gz'));
out('path-posix-extname-dotfile', path.posix.extname('/a/.bashrc'));
out('path-posix-resolve', path.posix.resolve('/a/b', '../c', 'd'));
out('path-posix-relative', path.posix.relative('/a/b/c', '/a/d/e'));
out('path-posix-relative-up', path.posix.relative('/a/b/c', '/a'));
out('path-posix-isabsolute', path.posix.isAbsolute('/a'));
out('path-posix-isabsolute-rel', path.posix.isAbsolute('a'));

const parsedPosix = path.posix.parse('/home/user/dir/file.txt');
out('path-posix-parse', [
  parsedPosix.root,
  parsedPosix.dir,
  parsedPosix.base,
  parsedPosix.ext,
  parsedPosix.name,
]);
out('path-posix-format', path.posix.format({
  dir: '/home/user',
  base: 'file.txt',
}));
out('path-posix-format-root', path.posix.format({
  root: '/',
  name: 'file',
  ext: '.txt',
}));

out('path-win32-join', path.win32.join('C:\\a', 'b', '..', 'c'));
out('path-win32-normalize', path.win32.normalize('C:\\a\\\\b\\..\\c\\'));
out('path-win32-directory', path.win32.dirname('C:\\a\\b\\c.txt'));
out('path-win32-basename', path.win32.basename('C:\\a\\b\\c.txt'));
out('path-win32-extname', path.win32.extname('C:\\a\\b\\c.tar.gz'));
out('path-win32-resolve', path.win32.resolve('C:\\a', '..\\b'));
out('path-win32-relative', path.win32.relative('C:\\a\\b', 'C:\\a\\c'));
out('path-win32-isabsolute', path.win32.isAbsolute('C:\\a'));
out('path-win32-isabsolute-rel', path.win32.isAbsolute('a\\b'));

const parsedWin32 = path.win32.parse('C:\\home\\user\\file.txt');
out('path-win32-parse', [
  parsedWin32.root,
  parsedWin32.dir,
  parsedWin32.base,
  parsedWin32.ext,
  parsedWin32.name,
]);
out('path-win32-format', path.win32.format({
  dir: 'C:\\home\\user',
  base: 'file.txt',
}));

// -------------------------------------------------------------- node:buffer

show('buffer-utf8', Buffer.from('héllo').toString('utf8'));
show('buffer-hex', Buffer.from('deadbeef', 'hex').toString('hex'));
show('buffer-hex-roundtrip', Buffer.from([0, 1, 254, 255]).toString('hex'));
show('buffer-base64', Buffer.from('hello world').toString('base64'));
show('buffer-base64url', Buffer.from('hello world??').toString('base64url'));
show('buffer-latin1', Buffer.from([0x68, 0xe9, 0x6c]).toString('latin1'));
show('buffer-utf16le', Buffer.from('hi', 'utf16le').toString('hex'));
show('buffer-concat', Buffer.concat([Buffer.from('ab'), Buffer.from('cd')]).toString('utf8'));
show('buffer-concat-total', Buffer.concat([Buffer.from('ab'), Buffer.from('cd')], 3).toString('utf8'));
show('buffer-bytelength', String(Buffer.byteLength('héllo', 'utf8')));
show('buffer-bytelength-base64', String(Buffer.byteLength('aGVsbG8=', 'base64')));
show('buffer-json', JSON.stringify(Buffer.from([1, 2, 3])));
show('buffer-slice', Buffer.from('abcdef').subarray(1, 4).toString('utf8'));
show('buffer-from-array', Buffer.from([0x61, 0x62, 0x63]).toString('utf8'));

// ----------------------------------------------------------------- node:url

const urls = [
  'https://user:pa%40ss@example.com:8443/a/b?x=1&y=2#frag',
  'http://example.com',
  'file:///tmp/a%20b.txt',
  'https://example.com/a/./b/../c',
];
for (const input of urls) {
  const parsed = new URL(input);
  out(`url-href:${input}`, parsed.href);
  out(`url-origin:${input}`, parsed.origin);
  out(`url-pathname:${input}`, parsed.pathname);
  out(`url-search:${input}`, parsed.search);
  out(`url-hash:${input}`, parsed.hash);
  out(`url-username:${input}`, parsed.username);
  out(`url-password:${input}`, parsed.password);
}

const base = new URL('https://example.com/dir/page?q=a#top');
out('url-relative-dotdot', new URL('../other?z=1', base).href);
out('url-relative-slash', new URL('/root', base).href);
out('url-set-search', (() => {
  const copy = new URL(base.href);
  copy.search = '?k=v';
  return copy.href;
})());
out('url-set-hash', (() => {
  const copy = new URL(base.href);
  copy.hash = 'next';
  return copy.href;
})());

const params = new URLSearchParams('a=1&a=2&b=hello+world&c=%26');
out('params-string', params.toString());
out('params-getall', params.getAll('a'));
out('params-get', params.get('b'));
out('params-roundtrip', new URLSearchParams(params.toString()).toString());
out('params-sorted', (() => {
  const copy = new URLSearchParams(params.toString());
  copy.sort();
  return copy.toString();
})());
out('params-entries', [...new URLSearchParams('x=1&y=2')]);
out('params-empty', new URLSearchParams('').toString());

// ---------------------------------------------------------------- node:util

show('util-format-s', util.format('%s', 'text'));
show('util-format-d', util.format('%d', 42));
show('util-format-d-string', util.format('%d', '42'));
show('util-format-i', util.format('%i', 3.9));
show('util-format-i-string', util.format('%i', '7.9'));
show('util-format-f', util.format('%f', 3.5));
show('util-format-f-string', util.format('%f', '2.25'));
show('util-format-j', util.format('%j', { a: 1, b: [2, 3] }));
show('util-format-j-circular', util.format('%j', (() => {
  const value = {};
  value.self = value;
  return value;
})()));
show('util-format-o-string', util.format('%o', 'two'));
show('util-format-o-number', util.format('%o', 42));
show('util-format-o-object', util.format('%o', { a: 1, b: 'two' }));
show('util-format-o-array', util.format('%o', [1, 2]));
show('util-format-o-empty-array', util.format('%o', []));
show('util-format-O', util.format('%O', { a: 1, b: 'two' }));
show('util-format-c', util.format('%c styled', 'color: red'));
show('util-format-percent', util.format('100%%'));
show('util-format-mixed', util.format('%s=%d', 'count', 5));
show('util-format-extra', util.format('plain', 'extra', 1));
show('util-format-no-args', util.format('plain'));
show('util-format-object', util.format({ a: 1 }));
