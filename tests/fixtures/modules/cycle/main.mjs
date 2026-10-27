// Phase 0: relative imports across four files with a cycle (plan §9).
import { a } from './a.mjs';
import { c, peek } from './c.mjs';

console.log(`a=${a}`);
console.log(`c=${c}`);
console.log(`peek=${peek()}`);
console.log(`main=${import.meta.main}`);
