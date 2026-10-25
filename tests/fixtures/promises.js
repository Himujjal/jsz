globalThis.__result = "";

Promise.all([Promise.resolve(1), Promise.resolve(2)])
    .then((values) => { globalThis.__result = values.join("+"); });
