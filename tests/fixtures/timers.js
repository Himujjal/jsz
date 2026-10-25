globalThis.__result = "";

setTimeout(() => { globalThis.__result += "a"; }, 20);
setTimeout(() => { globalThis.__result += "b"; }, 0);
setTimeout((value) => { globalThis.__result += value; }, 10, "c");
setTimeout(() => { globalThis.__result += "d"; }, 30);

Promise.resolve().then(() => { globalThis.__result += "m"; });
