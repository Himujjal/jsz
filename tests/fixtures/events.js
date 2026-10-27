// Ported from nodejs/node test/parallel/test-events-*.js. Covers listener
// order, once wrappers, remove semantics, error emission, meta events,
// maxListeners, and the static events.once helper.
import EventEmitter, { EventEmitter as NamedEventEmitter, once } from 'node:events';

const out = [];
const log = (line) => out.push(line);

const order = [];
const emitter = new EventEmitter();
emitter.on('go', function () {
  order.push(`b:${this === emitter}`);
});
emitter.on('go', () => order.push('a'));
log(`emit-order=${emitter.emit('go')}:${order.join(',')}`);
log(`emit-none=${emitter.emit('missing')}`);

const onceEmitter = new EventEmitter();
let onceCalls = 0;
const originalOnce = () => {
  onceCalls++;
};
onceEmitter.once('tick', originalOnce);
const rawOnce = onceEmitter.rawListeners('tick')[0];
log(`once-raw=${typeof rawOnce}:${rawOnce.listener === originalOnce}:${rawOnce !== originalOnce}`);
log(`once-listeners=${onceEmitter.listeners('tick')[0] === originalOnce}`);
onceEmitter.emit('tick');
onceEmitter.emit('tick');
log(`once-fired=${onceCalls}:${onceEmitter.listenerCount('tick')}`);

const removeEmitter = new EventEmitter();
let removedCalls = 0;
const removable = () => {
  removedCalls++;
};
removeEmitter.once('tick', removable);
removeEmitter.removeListener('tick', removable);
removeEmitter.emit('tick');
log(`remove-once=${removeEmitter.listenerCount('tick')}:${removedCalls}`);

const prepend = new EventEmitter();
const prependOrder = [];
prepend.on('x', () => prependOrder.push('on'));
prepend.prependListener('x', () => prependOrder.push('prepend'));
prepend.prependOnceListener('x', () => prependOrder.push('prepend-once'));
prepend.emit('x');
prepend.emit('x');
log(`prepend=${prependOrder.join(',')}`);

try {
  new EventEmitter().emit('error', new Error('boom'));
  log('error-throw=none');
} catch (error) {
  log(`error-throw=${error.name}:${error.message}`);
}
try {
  new EventEmitter().emit('error', 'string-error');
  log('error-wrap=none');
} catch (error) {
  log(`error-wrap=${error.code}:${error.context}`);
}

const meta = new EventEmitter();
const metaLog = [];
const metaListener = () => {};
meta.on('newListener', (name) => metaLog.push(`new:${name}`));
meta.on('removeListener', (name) => metaLog.push(`remove:${name}`));
meta.on('foo', metaListener);
meta.removeListener('foo', metaListener);
log(`meta=${metaLog.join(',')}`);
log(`event-names=${meta.eventNames().join(',')}`);

const late = new EventEmitter();
const lateLog = [];
late.on('y', () => {
  lateLog.push('first');
  late.on('y', () => lateLog.push('late'));
});
late.emit('y');
log(`during-emit=${lateLog.join(',')}:${late.listenerCount('y')}`);

const max = new EventEmitter();
log(`max-default=${max.getMaxListeners()}:${EventEmitter.defaultMaxListeners}`);
log(`max-set=${max.setMaxListeners(3) === max}:${max.getMaxListeners()}`);

const clear = new EventEmitter();
clear.on('a', () => {});
clear.on('b', () => {});
clear.removeAllListeners('a');
log(`remove-all-one=${clear.eventNames().join(',')}`);
clear.removeAllListeners();
log(`remove-all=${clear.eventNames().length}`);

log(`default-export=${NamedEventEmitter === EventEmitter}:${EventEmitter.EventEmitter === EventEmitter}:${typeof EventEmitter.once}`);

async function main() {
  const resolveEmitter = new EventEmitter();
  const ready = once(resolveEmitter, 'ready');
  setTimeout(() => resolveEmitter.emit('ready', 1, 2), 1);
  log(`once-resolve=${(await ready).join(',')}`);
  log(`once-cleanup=${resolveEmitter.listenerCount('ready')}:${resolveEmitter.listenerCount('error')}`);

  const rejectEmitter = new EventEmitter();
  const failing = once(rejectEmitter, 'ready');
  setTimeout(() => rejectEmitter.emit('error', new Error('failed')), 1);
  try {
    await failing;
    log('once-reject=none');
  } catch (error) {
    log(`once-reject=${error.name}:${error.message}`);
  }
  log(`once-reject-cleanup=${rejectEmitter.listenerCount('ready')}:${rejectEmitter.listenerCount('error')}`);

  const errorEmitter = new EventEmitter();
  const errorEvent = once(errorEmitter, 'error');
  setTimeout(() => errorEmitter.emit('error', new Error('direct')), 1);
  const [errorValue] = await errorEvent;
  log(`once-error=${errorValue.message}`);

  globalThis.__result = out.join('\n') + '\n';
}

main();
