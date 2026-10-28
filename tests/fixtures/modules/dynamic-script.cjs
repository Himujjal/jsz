// Script mode has no static imports, but `import()` uses the loader.
import("./dynamic-dep.mjs").then((m) => {
    console.log(`script=${m.value}`);
});
