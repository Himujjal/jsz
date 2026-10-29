// Exercises the JS console layer: `util.format` specifiers, the `dir` inspector,
// and the `timeEnd` missing-label warning. Timing output is asserted by shape.
console.log('%s|%d|%i|%f|%j|%%', 'a', 1, 2, 3, { k: 1 });
console.log('plain');
console.log('multi', 1, true);
console.info('info');
console.warn('warn');
console.error('err');
console.debug('debug');
console.dir({ a: 1 }, { depth: 0 });
console.assert(true, 'never runs');
console.timeEnd('missing');
console.time('t');
console.timeEnd('t');
