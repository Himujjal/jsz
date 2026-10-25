globalThis.__result = "";

let count = 0;
const id = setInterval(() => {
    count += 1;
    if (count === 3) {
        clearInterval(id);
        globalThis.__result = "ticks=" + count;
    }
}, 5);
