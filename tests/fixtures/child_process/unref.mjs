// `unref()` must not keep the event loop alive for the child's lifetime.
import { spawn } from 'node:child_process';

const child = spawn('/bin/sleep', ['2']);
child.unref();
setTimeout(() => console.log('unref=done'), 20);
