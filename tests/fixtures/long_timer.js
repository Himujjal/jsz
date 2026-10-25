globalThis.__result = "";

const start = Date.now();
setTimeout(() => {
    globalThis.__result = "elapsed=" + (Date.now() - start);
}, 2200);
