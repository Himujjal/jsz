// `performance` mirrors the browser surface: monotonic `now()` plus a constant
// `timeOrigin` anchor. `global` must alias the global object.
console.log(`global=${globalThis.global === globalThis}`);

async function main() {
  const before = performance.now();
  const origin = performance.timeOrigin;
  await sleep(10);
  const after = performance.now();

  console.log(`advances=${after > before}`);
  console.log(`origin=${origin <= Date.now()}`);
  console.log(`constant=${performance.timeOrigin === origin}`);
}

main();
