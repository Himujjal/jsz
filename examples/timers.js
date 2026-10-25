console.log("start");

const interval = setInterval(() => {
    console.log("tick");
}, 100);

setTimeout(() => {
    clearInterval(interval);
    console.log("done");
}, 350);
