import { join } from "node:path";
import * as bare from "path";
import double, { value } from "./dep.mjs";

console.log("value=" + value);
console.log("double=" + double(21));
console.log("join=" + join("/a", "b"));
console.log("alias_same=" + (join === bare.join));
