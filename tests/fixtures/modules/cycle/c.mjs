import { a } from './a.mjs';

export const c = 'c';

// Reading `a` during evaluation would hit the temporal dead zone, so the
// cycle is observed through a live binding after evaluation finishes.
export function peek() {
  return a;
}
