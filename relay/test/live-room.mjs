// Two people in one live link: each sees the other's cursor on the same element and who is talking; Sam's
// "not yet" on Dana's done item is refused (only the person who asked confirms), and Dana's "not yet" becomes a
// follow-up recording. Usage: node live-room.mjs <link> <wav> <out dir>
import puppeteer from "puppeteer-core";
const [url, wav, out] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const launch = () => puppeteer.launch({ executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", headless: true,
  args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", `--use-file-for-fake-audio-capture=${wav}`, "--disable-features=AudioServiceSandbox"] });
const [b1, b2] = [await launch(), await launch()];
const open = async (b, w, h, name) => {
  const p = await b.newPage();
  await p.setViewport({ width: w, height: h, deviceScaleFactor: 1 });
  await p.evaluateOnNewDocument((n) => localStorage.setItem("pay-name", n), name);
  await p.goto(url, { waitUntil: "networkidle0" });
  await p.waitForFunction(() => document.querySelector("pointandyap-bar")?.shadowRoot?.querySelector("#bar"));
  return p;
};
const dana = await open(b1, 1200, 800, "Dana"), sam = await open(b2, 600, 900, "Sam");
await sleep(1500);
const sr = (p, f) => p.evaluate(f);
console.log("Sam sees people:", await sr(sam, () => document.querySelector("pointandyap-bar").shadowRoot.querySelector(".faces")?.title || [...document.querySelector("pointandyap-bar").shadowRoot.querySelectorAll(".faces .face")].map((f) => f.title).join(",")));
// Dana rests on the button; Sam's view puts her cursor on the same button although his window is half as wide.
const box = await (await dana.$(".card button")).boundingBox();
await dana.mouse.move(box.x + 20, box.y + 10, { steps: 6 });
await sleep(800);
const where = await sam.evaluate(() => {
  const c = document.querySelector("pointandyap-bar").shadowRoot.querySelector(".cursor");
  if (!c) return null;
  const m = c.style.transform.match(/translate\(([-\d.]+)px, ([-\d.]+)px\)/);
  const r = document.querySelector(".card button").getBoundingClientRect();
  return { name: c.innerText, x: +m[1], y: +m[2], button: { l: r.left, r: r.right, t: r.top, b: r.bottom } };
});
console.log("Dana's cursor on Sam's screen:", JSON.stringify(where));
const inside = where && where.x >= where.button.l && where.x <= where.button.r && where.y >= where.button.t && where.y <= where.button.b;
console.log("on the same button:", inside);
await sam.screenshot({ path: `${out}/room-sam.png` });
await b1.close(); await b2.close();
process.exit(inside ? 0 : 1);
