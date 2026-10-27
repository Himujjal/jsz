import path, { posix, win32 } from 'node:path';

const out = (label, value) => console.log(`${label}=${JSON.stringify(value)}`);

// POSIX: normalize
out('posix-normalize-empty', posix.normalize(''));
out('posix-normalize-dot', posix.normalize('.'));
out('posix-normalize-dotdot', posix.normalize('..'));
out('posix-normalize-slash', posix.normalize('/'));
out('posix-normalize-double-slash', posix.normalize('//'));
out('posix-normalize-triple-slash', posix.normalize('///'));
out('posix-normalize-a-dotdot-b', posix.normalize('a/../b'));
out('posix-normalize-dot-a', posix.normalize('./a'));
out('posix-normalize-a-double-b-slash', posix.normalize('a//b/'));
out('posix-normalize-a-up-up-b', posix.normalize('/a/../../b'));
out('posix-normalize-a-dotdot', posix.normalize('a/..'));
out('posix-normalize-up-a', posix.normalize('../a'));
out('posix-normalize-a-b-up-up', posix.normalize('/a/b/../..'));

// POSIX: join
out('posix-join-none', posix.join());
out('posix-join-empty', posix.join(''));
out('posix-join-one', posix.join('a'));
out('posix-join-many', posix.join('/a', 'b', 'c'));
out('posix-join-dotdot', posix.join('a', '..', 'b'));
out('posix-join-above-root', posix.join('/a', '../..', 'b'));
out('posix-join-empty-middle', posix.join('a', '', 'b'));
out('posix-join-unc-like', posix.join('//a', 'b'));

// POSIX: isAbsolute
out('posix-isabsolute-empty', posix.isAbsolute(''));
out('posix-isabsolute-slash', posix.isAbsolute('/'));
out('posix-isabsolute-a', posix.isAbsolute('a'));
out('posix-isabsolute-slash-a', posix.isAbsolute('/a'));
out('posix-isabsolute-double-slash-a', posix.isAbsolute('//a'));
out('posix-isabsolute-a-b', posix.isAbsolute('a/b'));

// POSIX: dirname
out('posix-dirname-empty', posix.dirname(''));
out('posix-dirname-slash', posix.dirname('/'));
out('posix-dirname-double-slash', posix.dirname('//'));
out('posix-dirname-slash-a', posix.dirname('/a'));
out('posix-dirname-a', posix.dirname('a'));
out('posix-dirname-slash-a-b', posix.dirname('/a/b'));
out('posix-dirname-slash-a-up-slash', posix.dirname('/a/../'));
out('posix-dirname-slash-a-b-slash', posix.dirname('/a/b/'));
out('posix-dirname-double-slash-a', posix.dirname('//a'));

// POSIX: basename
out('posix-basename-file', posix.basename('/a/b.txt'));
out('posix-basename-suffix', posix.basename('/a/b.txt', '.txt'));
out('posix-basename-root', posix.basename('/'));
out('posix-basename-empty', posix.basename(''));
out('posix-basename-trailing', posix.basename('a/b/'));
out('posix-basename-double-slash-a', posix.basename('//a'));
out('posix-basename-full-suffix', posix.basename('/a/b.txt', 'b.txt'));
out('posix-basename-mismatch', posix.basename('a/b.txt', '.md'));

// POSIX: extname
out('posix-extname-bashrc', posix.extname('.bashrc'));
out('posix-extname-a-b-c', posix.extname('a.b.c'));
out('posix-extname-a-dot', posix.extname('a.'));
out('posix-extname-dotdot', posix.extname('..'));
out('posix-extname-dot', posix.extname('.'));
out('posix-extname-a-b-dot-x', posix.extname('a/b/.x'));
out('posix-extname-file', posix.extname('/a/b.txt'));
out('posix-extname-dots', posix.extname('...'));

// POSIX: parse
out('posix-parse-empty', posix.parse(''));
out('posix-parse-root', posix.parse('/'));
out('posix-parse-file', posix.parse('/a/b.txt'));
out('posix-parse-multi-dot', posix.parse('a.b.c'));
out('posix-parse-trailing', posix.parse('/a/b/'));
out('posix-parse-bashrc', posix.parse('.bashrc'));
out('posix-parse-dotdot', posix.parse('/a/../b'));

// POSIX: format
out('posix-format-empty', posix.format({}));
out('posix-format-root-name', posix.format({ root: '/', name: 'a' }));
out('posix-format-root-ext', posix.format({ root: '/', ext: '.txt' }));
out('posix-format-dir-base', posix.format({ dir: '/a', base: 'b.txt' }));
out('posix-format-dir-root-base', posix.format({ dir: '/a', root: '/', base: 'b' }));
out('posix-format-dir-name-ext', posix.format({ dir: '/a', name: 'x', ext: '.y' }));
out('posix-format-base-precedence', posix.format({ dir: '/a', base: 'b', name: 'ignored', ext: '.c' }));
out('posix-format-name-ext-no-dot', posix.format({ name: 'x', ext: 'y' }));
out('posix-format-empty-dir', posix.format({ root: '/', dir: '', name: 'x' }));

// POSIX: relative
out('posix-relative-equal', posix.relative('/a/b', '/a/b'));
out('posix-relative-sibling', posix.relative('/a/b', '/a/c'));
out('posix-relative-ancestor', posix.relative('/a/b/c', '/a/b'));
out('posix-relative-descendant', posix.relative('/a/b', '/a/b/c'));
out('posix-relative-cousin', posix.relative('/a/b/c', '/x/y'));
out('posix-relative-root-to-a', posix.relative('/', '/a'));
out('posix-relative-a-to-root', posix.relative('/a', '/'));
out('posix-relative-trailing', posix.relative('/a/b/', '/a/b/c'));
out('posix-relative-exact-base', posix.relative('/a/b', '/a/b/c/d'));

// POSIX: resolve (cwd-independent inputs)
out('posix-resolve-parent', posix.resolve('/a/b', '../c'));
out('posix-resolve-absolute-wins', posix.resolve('/a', '/b', 'c'));
out('posix-resolve-relative-then-absolute', posix.resolve('a', '/b'));
out('posix-resolve-dotdot', posix.resolve('/a', '..', 'b'));
out('posix-resolve-root', posix.resolve('/'));

// POSIX: toNamespacedPath
out('posix-namespaced', posix.toNamespacedPath('/a/b'));

// POSIX: resolve reads the live cwd (booleans keep output cwd-independent).
out('posix-resolve-cwd-joined', posix.resolve('x') === posix.join(process.cwd(), 'x'));
out('posix-resolve-cwd-dot', posix.resolve('.') === process.cwd());
out('posix-relative-cwd', posix.relative('a', 'b') === '../b');
out('win32-resolve-cwd-tail', win32.resolve('x').endsWith('\\x') && win32.resolve('x').startsWith('\\'));
out('win32-relative-cwd', win32.relative('a', 'b') === '..\\b');

// Win32: normalize
out('win32-normalize-empty', win32.normalize(''));
out('win32-normalize-drive-root', win32.normalize('C:\\'));
out('win32-normalize-mixed', win32.normalize('c:/a/b/../c'));
out('win32-normalize-unc', win32.normalize('\\\\server\\share\\a\\..\\b'));
out('win32-normalize-device', win32.normalize('\\\\?\\C:\\a\\..'));
out('win32-normalize-drive-relative', win32.normalize('C:a'));
out('win32-normalize-trailing', win32.normalize('C:/a//b/'));
out('win32-normalize-above-root', win32.normalize('C:\\a\\..\\..\\b'));

// Win32: resolve (absolute inputs)
out('win32-resolve-dotdot', win32.resolve('C:\\a', '..', 'b'));
out('win32-resolve-other-drive', win32.resolve('C:\\a', 'D:\\b'));
out('win32-resolve-unc', win32.resolve('\\\\server\\share\\a'));
out('win32-resolve-drive', win32.resolve('C:\\a'));
out('win32-resolve-slash', win32.resolve('/a'));
out('win32-resolve-forward', win32.resolve('C:/a'));

// Win32: isAbsolute
out('win32-isabsolute-drive', win32.isAbsolute('C:\\a'));
out('win32-isabsolute-drive-relative', win32.isAbsolute('C:a'));
out('win32-isabsolute-root', win32.isAbsolute('\\a'));
out('win32-isabsolute-slash', win32.isAbsolute('/a'));

// Win32: dirname
out('win32-dirname-drive', win32.dirname('C:\\a\\b'));
out('win32-dirname-root', win32.dirname('C:\\'));
out('win32-dirname-unc', win32.dirname('\\\\server\\share\\a'));
out('win32-dirname-drive-only', win32.dirname('C:'));
out('win32-dirname-trailing', win32.dirname('C:\\a\\'));

// Win32: basename
out('win32-basename-file', win32.basename('C:\\a\\b.txt'));
out('win32-basename-suffix', win32.basename('C:\\a\\b.txt', '.txt'));
out('win32-basename-unc', win32.basename('\\\\server\\share\\a'));
out('win32-basename-root', win32.basename('C:\\'));
out('win32-basename-drive-only', win32.basename('C:'));
out('win32-basename-trailing', win32.basename('/a/b/'));

// Win32: extname
out('win32-extname-file', win32.extname('C:\\a\\b.txt'));
out('win32-extname-bashrc', win32.extname('C:\\a\\.bashrc'));
out('win32-extname-drive-relative', win32.extname('C:a.b'));
out('win32-extname-unc-tar', win32.extname('\\\\server\\share\\a.tar.gz'));
out('win32-extname-trailing-dot', win32.extname('C:\\a\\b.'));

// Win32: parse
out('win32-parse-drive', win32.parse('C:\\a\\b.txt'));
out('win32-parse-root', win32.parse('C:\\'));
out('win32-parse-drive-only', win32.parse('C:'));
out('win32-parse-unc', win32.parse('\\\\server\\share\\a\\b'));
out('win32-parse-drive-relative', win32.parse('C:a'));
out('win32-parse-empty', win32.parse(''));
out('win32-parse-unc-root', win32.parse('\\\\server\\share\\'));

// Win32: format
out('win32-format-root-name', win32.format({ root: 'C:\\', name: 'a' }));
out('win32-format-dir-base', win32.format({ dir: 'C:\\a', base: 'b.txt' }));
out('win32-format-root-ext', win32.format({ root: 'C:\\', ext: '.txt' }));
out('win32-format-dir-wins', win32.format({ dir: 'C:\\a', root: 'C:\\', base: 'b' }));
out('win32-format-name-ext', win32.format({ name: 'x', ext: 'y' }));
out('win32-format-empty', win32.format({}));

// Win32: toNamespacedPath
out('win32-namespaced-drive', win32.toNamespacedPath('C:\\a'));
out('win32-namespaced-unc', win32.toNamespacedPath('\\\\server\\share\\a'));
out('win32-namespaced-already', win32.toNamespacedPath('\\\\?\\C:\\a'));
out('win32-namespaced-empty', win32.toNamespacedPath(''));

// Win32: relative
out('win32-relative-sibling', win32.relative('C:\\a\\b', 'C:\\a\\c'));
out('win32-relative-equal', win32.relative('C:\\a\\b', 'C:\\a\\b'));
out('win32-relative-child', win32.relative('C:\\a', 'C:\\a\\b'));
out('win32-relative-parent', win32.relative('C:\\a\\b', 'C:\\a'));
out('win32-relative-cousin', win32.relative('C:\\a', 'C:\\b'));
out('win32-relative-case', win32.relative('C:\\a', 'c:\\a\\b'));
out('win32-relative-unc-child', win32.relative('\\\\server\\share\\a', '\\\\server\\share\\a\\b'));

// Top-level exports and namespaces
out('top-join', path.join('/a', '../b'));
out('top-default-is-posix', path === posix);
out('posix-join-matches-named', posix.join('/a/b', '..', 'c'));
out('posix-sep', posix.sep);
out('posix-delimiter', posix.delimiter);
out('win32-sep', win32.sep);
out('win32-delimiter', win32.delimiter);
out('win32-namespace-sep', win32.sep === '\\');
out('top-namespaced', path.toNamespacedPath('/a/../b'));
