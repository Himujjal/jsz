async function main() {
    console.log("start");

    await sleep(50);

    const values = await Promise.all([
        sleep(10).then(() => "a"),
        Promise.resolve("b"),
    ]);
    console.log("values:", values.join(","));

    await sleep(10);
    console.log("done");
}

main();
