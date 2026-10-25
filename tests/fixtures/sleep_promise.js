globalThis.__result = "";

const sleep = (time) => new Promise((res) => setTimeout(res, time));

async function main() {
    await sleep(5);
    globalThis.__result += "a";
    await sleep(5);
    globalThis.__result += "b";
}

main();
