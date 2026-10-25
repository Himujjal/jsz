globalThis.__result = "";

async function main() {
    await sleep(5);
    globalThis.__result = "slept";
}

main();
