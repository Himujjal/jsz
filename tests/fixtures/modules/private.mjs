// Phase 0: `node:_*` specifiers are private to embedded builtins (plan §4.2).
import * as internals from 'node:_fs';

console.log(`loaded=${typeof internals.readFile}`);
