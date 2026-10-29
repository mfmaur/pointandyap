// A guest in real Chrome: fake mic plays guest.wav; rests on Save, then on the date label; stops; sends.
import puppeteer from "puppeteer-core";
const [url, wav, out] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const browser = await puppeteer.launch({
  executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", headless: true,
  args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", `--use-file-for-fake-audio-capture=${wav}`, "--autoplay-policy=no-user-gesture-required",
    // The sandboxed audio service cannot read the fake-capture file: it records silence without this.
    "--disable-features=AudioServiceSandbox"],
});
const page = await browser.newPage();
const problems = [];
page.on("console", (m) => m.type() === "error" && problems.push(m.text()));
page.on("pageerror", (e) => problems.push(String(e)));
await page.setViewport({ width: 1200, height: 900, deviceScaleFactor: 2 });
await page.goto(url, { waitUntil: "networkidle0" });
await page.waitForSelector("#stage:not([hidden])", { timeout: 10000 });
await page.screenshot({ path: `${out}/1-open.png` });
await page.type("#name", "Dana");
await page.click("#start");
await page.waitForSelector("#recording:not([hidden])");
await page.$eval("#shot", (e) => e.scrollIntoView({ block: "center" }));
const box = await (await page.$("#shot")).boundingBox();
console.log("screenshot box fits the window:", box.y >= 0 && box.y + box.height <= 900, JSON.stringify(box));
const go = async (nx, ny, ms) => { await page.mouse.move(box.x + nx * box.width, box.y + ny * box.height, { steps: 8 }); await sleep(ms); };
await go(0.267, 0.249, 1600);          // Save button (385, 224 of 1440 x 900)
await go(0.6875, 0.558, 1600);         // "Last sync: 3 days ago" (990, 502)
await page.screenshot({ path: `${out}/2-recording.png` });
await sleep(1300);
await page.click("#stop");
await page.waitForSelector("#review:not([hidden])");
console.log("summary:", await page.$eval("#summary", (e) => e.textContent));
await page.screenshot({ path: `${out}/3-review.png` });
await page.click("#send");
await page.waitForSelector("#sent:not([hidden])", { timeout: 15000 });
console.log("sent:", await page.$eval("#sentText", (e) => e.textContent));
await page.screenshot({ path: `${out}/4-sent.png` });
// Phone width, typed feedback.
await page.setViewport({ width: 390, height: 844, deviceScaleFactor: 2 });
await page.click("#more"); await page.click("#typeMode");
await page.$eval("#shot", (e) => e.scrollIntoView({ block: "center" }));
const b2 = await (await page.$("#shot")).boundingBox();
await page.mouse.click(b2.x + 0.267 * b2.width, b2.y + 0.249 * b2.height);
await page.type("#text", "should be blue");
await page.screenshot({ path: `${out}/5-phone-typing.png` });
await page.click("#sendText");
await page.waitForSelector("#sent:not([hidden])", { timeout: 15000 });
console.log("typed sent; text was:", "[1] should be blue");
console.log("page errors:", problems.length ? problems : "none");
await browser.close();
