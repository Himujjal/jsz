import { basename } from "path";

export const detected = true;
console.log("auto=" + basename("/a/b/c.txt"));
