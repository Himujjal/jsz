// Phase 0: import.meta.url and import.meta.main (plan §4.8).
import { depMeta } from './meta-dep.mjs';

console.log(`url-scheme=${import.meta.url.startsWith('file://')}`);
console.log(`url-suffix=${import.meta.url.endsWith('/modules/meta.mjs')}`);
console.log(`main=${import.meta.main}`);
console.log(`dep-main=${depMeta.main}`);
console.log(`dep-url=${depMeta.url.endsWith('/modules/meta-dep.mjs')}`);
