// Exercises node:url with no timers and no filesystem access so the output is
// deterministic. `tests/zig/url_test.zig` asserts the exact strings.

import url, { URL, URLSearchParams, pathToFileURL, fileURLToPath, urlToHttpOptions } from 'node:url';
import process from 'node:process';

const lines = [];
const add = (key, value) => lines.push(`${key}=${value}`);

const parsed = new URL('https://a/b?c#d');
add('href', parsed.href);
add('protocol', parsed.protocol);
add('host', parsed.host);
add('hostname', parsed.hostname);
add('port', JSON.stringify(parsed.port));
add('pathname', parsed.pathname);
add('search', parsed.search);
add('hash', parsed.hash);
add('origin', parsed.origin);

add('relative', new URL('../x?y', 'https://ex.com/a/b/c').href);
add('dots', new URL('/a/./b/../c', 'https://ex.com/x/y').href);
add('credentials', new URL('https://user:pa%40ss@Ex.COM:443/p').href);

const params = parsed.searchParams;
params.append('e', 'f');
add('params-href', parsed.href);
parsed.search = '?g=h&g=i';
add('params-sync', params.toString());
add('params-getall', params.getAll('g').join(','));
params.sort();
add('params-sort', params.toString());
add('params-size', params.size);
params.delete('g', 'i');
add('params-delete', params.toString());
add('params-entries', [...params].map(([key, value]) => `${key}:${value}`).join(','));
add('params-keys', [...params.keys()].join(','));
add('params-values', [...params.values()].join(','));
params.set('x', 'a b');
add('params-set', params.toString());
add('params-href2', parsed.href);

const search = new URLSearchParams('?a=1&a=2&b');
add('sp-string', search.toString());
add('sp-get', search.get('a'));
add('sp-getall', search.getAll('a').join(','));
add('sp-has', String(search.has('b')) + ':' + String(search.has('a', '2')));
add('sp-object', new URLSearchParams({ a: '1', b: 'two words', c: undefined }).toString());
add('sp-iterable', new URLSearchParams([['a', '1'], ['a', '2']]).toString());
add('sp-plus', new URLSearchParams('q=a+b').get('q'));
add('sp-unicode', new URLSearchParams('q=✓').toString());

add('default-http', JSON.stringify(new URL('http://a:80/').port) + ':' + new URL('http://a:80/').href);
add('default-https', new URL('https://a:443/x').href);
add('keep-custom', new URL('https://a:8443/x').href);
add('origin-file', new URL('file:///tmp/x').origin);
add('origin-data', new URL('data:text/plain,hi').origin);
add('origin-ws', new URL('ws://a:80/x').origin);

add('canparse-ok', String(URL.canParse('https://a/b')));
add('canparse-bad', String(URL.canParse('nope')));
add('canparse-base', String(URL.canParse('x', 'https://a/')));
add('canparse-badbase', String(URL.canParse('https://a', 'nope')));
add('parse-ok', URL.parse('https://a/b').href);
add('parse-bad', String(URL.parse('nope')));
try {
  new URL('nope');
} catch (error) {
  add('invalid', `${error.name}:${error.code}:${error.message}:${error.input}`);
}

const fileUrl = pathToFileURL('/tmp/a b#c?d%');
add('file-url', fileUrl.href);
add('file-url-instance', String(fileUrl instanceof URL));
add('file-url-relative', String(pathToFileURL('a/b').href === pathToFileURL(`${process.cwd()}/a/b`).href));
add('file-path', fileURLToPath('file:///tmp/a%20b'));
add('file-path-roundtrip', fileURLToPath(pathToFileURL('/tmp/x y')));
add('file-path-localhost', fileURLToPath('file://localhost/tmp/x'));
try {
  fileURLToPath('http://a/b');
} catch (error) {
  add('file-scheme', error.code);
}
try {
  fileURLToPath('file://host/tmp/x');
} catch (error) {
  add('file-host', error.code);
}
try {
  fileURLToPath('file:///tmp/a%2Fb');
} catch (error) {
  add('file-encoded-slash', error.code);
}
try {
  fileURLToPath('file:///tmp/a%00b');
} catch (error) {
  add('file-null', error.code);
}

const httpOptions = urlToHttpOptions(new URL('https://user:pa%40ss@a:8443/x?y#z'));
add('http-options', [
  httpOptions.protocol,
  httpOptions.hostname,
  httpOptions.port,
  httpOptions.path,
  httpOptions.auth,
  httpOptions.href,
].join('|'));

add('default-export', [typeof url.URL, typeof url.URLSearchParams, typeof url.pathToFileURL, typeof url.fileURLToPath, typeof url.urlToHttpOptions].join(','));
add('string', String(parsed) === parsed.href);
add('json', JSON.stringify(parsed));

globalThis.__result = lines.join('\n') + '\n';
