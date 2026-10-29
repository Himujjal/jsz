import { basename } from "node:path";

console.log(`name=${basename(process.argv[0])}`);
console.log(`argv0=${process.argv[0]}`);
console.log(`argv1=${process.argv[1]}`);
console.log(`args=${process.argv.slice(2).join(",")}`);
console.log(`main=${import.meta.main}`);
console.log(`url=${import.meta.url}`);
