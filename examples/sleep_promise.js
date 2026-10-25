const sleep = (time) => new Promise((res) => setTimeout(res, time));

async function main() {
    console.log("start");
    await sleep(10);
    console.log("slept");
    await sleep(5);
    console.log("done");
}

main();
