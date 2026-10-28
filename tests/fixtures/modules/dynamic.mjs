// Phase 0 P1: dynamic import from entry, timer, and microtask callbacks.
import { value as staticValue } from "./dynamic-dep.mjs";

const first = await import("./dynamic-dep.mjs");
const second = await import("./dynamic-dep.mjs");
console.log(`top=${first.value} default=${first.default(3)} same=${first === second} static=${staticValue}`);

const tla = await import("./dynamic-tla.mjs");
console.log(`tla=${tla.before},${tla.after}`);

const path = await import("node:path");
const bare = await import("path");
console.log(`builtin=${path.join("a", "b")} alias=${path.join === bare.join}`);

const fileUrl = await import(new URL("./dynamic-dep.mjs", import.meta.url).href);
console.log(`file-url=${fileUrl.value} same=${fileUrl === first}`);

const spaced = await import(new URL("./space name.mjs", import.meta.url).href);
console.log(`space=${spaced.value}`);

const dir = await import("./dir");
console.log(`dir=${dir.dir}`);

try {
    await import("./does-not-exist.mjs");
} catch (e) {
    console.log(`missing=${e.name}:${e.code}`);
}

try {
    await import("node:nope");
} catch (e) {
    console.log(`unknown-builtin=${e.name}:${e.code}`);
}

try {
    await import("lodash");
} catch (e) {
    console.log(`package=${e.name}:${e.code}`);
}

try {
    await import("https://example.com/x.mjs");
} catch (e) {
    console.log(`scheme=${e.name}:${e.code}`);
}

try {
    await import("./dynamic-throws.mjs");
} catch (e) {
    console.log(`throws=${e.name}:${e.message}`);
}

try {
    await import("./dynamic-tla-throws.mjs");
} catch (e) {
    console.log(`tla-throws=${e.message}`);
}

try {
    await import("./dynamic-syntax-error.mjs");
} catch (e) {
    console.log(`syntax=${e.name}`);
}

setTimeout(async () => {
    const timer = await import("./dynamic-dep.mjs");
    console.log(`timer=${timer.value} same=${timer === first}`);
    try {
        await import("./dynamic-throws.mjs");
    } catch (e) {
        console.log(`timer-throws=${e.message}`);
    }
}, 0);

queueMicrotask(async () => {
    const microtask = await import("./dynamic-tla.mjs");
    console.log(`microtask=${microtask.after}`);
});
