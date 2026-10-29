// A guest on a live link in real Chrome: the app is the real one (a Vite + React dev server behind PointAndYap --live).
// The fake microphone plays guest.wav while the guest rests on the counter button and clicks it; the recording is sent.
// Then the guest waits for the agent's fix to arrive through hot reload and for "Done", and answers "Looks right".
// Usage: node live-guest.mjs <link> <wav> <out dir> [phase: send|check|both]
// TWO=1: one recording that asks for two things (the button green, then the heading), each fixed and confirmed on its own.
import puppeteer from "puppeteer-core";
const [url, wav, out, phase = "both"] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const browser = await puppeteer.launch({
  executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", headless: true,
  args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", `--use-file-for-fake-audio-capture=${wav}`,
    "--autoplay-policy=no-user-gesture-required", "--disable-features=AudioServiceSandbox"],
});
const page = await browser.newPage();
const problems = [];
page.on("console", (m) => m.type() === "error" && problems.push(m.text()));
page.on("pageerror", (e) => problems.push(String(e)));
await page.setViewport({ width: 1100, height: 800, deviceScaleFactor: 2 });
await page.goto(url, { waitUntil: "networkidle0" });
await page.waitForFunction(() => document.querySelector("pointandyap-bar"), { timeout: 10000 });
await sleep(800);
const button = await page.$(".card button");
const initial = await page.$eval(".card button", (b) => getComputedStyle(b).backgroundColor);
const info = await page.evaluate(() => {
  const b = document.querySelector(".card button").getBoundingClientRect();
  const d = window.__pointandyap.describe(b.left + 10, b.top + 10);
  return { d, stack: d && Object.getOwnPropertyDescriptor(d, "stack")?.value?.split("\n").slice(0, 4) };
});
console.log("element:", JSON.stringify({ role: info.d.role, text: info.d.text, sel: info.d.sel, comp: info.d.comp, src: info.d.src }));
const resolved = await page.evaluate(async () => {
  const b = document.querySelector(".card button").getBoundingClientRect();
  const d = window.__pointandyap.describe(b.left + 10, b.top + 10);
  const st = Object.getOwnPropertyDescriptor(d, "stack")?.value;
  return d.src || (st ? await window.__pointandyap.resolve(st) : null);
});
console.log("source:", resolved);
await page.screenshot({ path: `${out}/live-1-open.png` });

// The bar is driven the way a person does: ⌥ twice, typing, the pointer; its buttons are in its shadow root.
const press = async () => { await page.keyboard.down("Alt"); await page.keyboard.up("Alt"); await sleep(80); await page.keyboard.down("Alt"); await page.keyboard.up("Alt"); };
const bar = async () => (await page.$("pointandyap-bar")).boundingBox();

const TWO = !!process.env.TWO;
const shadow = (fn, ...a) => page.evaluate((fn, ...a) => new Function("r", "...a", fn)(document.querySelector("pointandyap-bar").shadowRoot, ...a), fn, ...a);
const initialTitle = await page.$eval("h1", (h) => h.textContent);
console.log("welcome:", await shadow("return r.querySelector('#panel').innerText.replace(/\\s+/g, ' ').slice(0, 90)"));

if (TWO && (phase === "send" || phase === "both")) {
  const box = await button.boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2, { steps: 5 });
  await press();
  await sleep(400);
  await page.keyboard.type("Dana");
  await page.keyboard.press("Enter");
  await sleep(2600);
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  const h1 = await (await page.$("h1")).boundingBox();
  await page.mouse.move(h1.x + 60, h1.y + h1.height / 2, { steps: 5 });
  await sleep(2000);
  console.log("marks while recording:", await shadow("return [...r.querySelectorAll('#marks .mark')].filter((m) => !m.hidden).map((m) => m.firstChild.textContent || 'hover').join(',')"));
  console.log("hint:", await shadow("return r.querySelector('.hint')?.textContent"));
  await page.screenshot({ path: `${out}/live-3-recording.png` });
  await sleep(1800);
  await press();
  await sleep(2500);
  await page.screenshot({ path: `${out}/live-4-sent.png` });
} else if (phase === "send" || phase === "both") {
  // First time: the bar asks for a name.
  await press();
  await sleep(400);
  await page.screenshot({ path: `${out}/live-2-name.png` });
  await page.keyboard.type("Dana");
  await page.keyboard.press("Enter");
  await sleep(1200);
  const box = await button.boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2, { steps: 10 });
  await sleep(1800);
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  await sleep(600);
  const h1 = await (await page.$("h1")).boundingBox();
  await page.mouse.move(h1.x + 40, h1.y + h1.height / 2, { steps: 10 });
  await sleep(1800);
  await page.screenshot({ path: `${out}/live-3-recording.png` });
  await press();
  await sleep(2500);
  await page.screenshot({ path: `${out}/live-4-sent.png` });
  console.log("count after click:", await page.$eval(".card button", (b) => b.textContent));
}

if (TWO && (phase === "check" || phase === "both")) {
  let agentSeen = null;
  const poll = setInterval(async () => { try { agentSeen ||= await shadow("return r.querySelector('.agent')?.textContent || null"); } catch {} }, 300);
  console.log("waiting for both fixes…");
  await page.waitForFunction((b, t) => getComputedStyle(document.querySelector(".card button")).backgroundColor !== b && document.querySelector("h1").textContent !== t,
    { timeout: 180000 }, initial, initialTitle);
  console.log("button now", await page.$eval(".card button", (b) => getComputedStyle(b).backgroundColor), "heading now", await page.$eval("h1", (h) => h.textContent));
  for (let n = 0; n < 2; n++) {
    await page.waitForFunction(() => document.querySelector("pointandyap-bar").shadowRoot.querySelector("[data-ok]"), { timeout: 30000 });
    await sleep(1200);
    if (n === 0) await page.screenshot({ path: `${out}/live-5-done.png` });
    console.log("check card:", await shadow("return r.querySelector('#panel').innerText.replace(/\\s+/g, ' ')"));
    await shadow("r.querySelector('[data-ok]').click()");
    await sleep(1500);
  }
  clearInterval(poll);
  console.log("agent badge seen:", agentSeen);
  await shadow("r.querySelector('#list').click()");
  await page.waitForFunction(() => (document.querySelector("pointandyap-bar").shadowRoot.querySelector("#panel").innerText.match(/Confirmed/g) || []).length === 2, { timeout: 10000 });
  await page.screenshot({ path: `${out}/live-6-confirmed.png` });
  console.log("both confirmed in the panel");
} else if (phase === "check" || phase === "both") {
  // The agent changes the button; hot reload brings it here without a reload of the page.
  const look = () => page.$eval(".card button", (b) => getComputedStyle(b).backgroundColor);
  const before = initial;
  console.log("waiting for the fix…");
  await page.waitForFunction((b) => getComputedStyle(document.querySelector(".card button")).backgroundColor !== b, { timeout: 180000 }, before);
  console.log("button background now:", await look(), "(was", before + "), count kept:", await page.$eval(".card button", (b) => b.textContent));
  await sleep(2500);
  await page.screenshot({ path: `${out}/live-5-done.png` });
  const clickIn = (sel) => page.evaluate((sel) => { const b = document.querySelector("pointandyap-bar").shadowRoot.querySelector(sel); b?.click(); return !!b; }, sel);
  await page.waitForFunction(() => document.querySelector("pointandyap-bar").shadowRoot.querySelector("[data-ok]"), { timeout: 30000 })
    .catch(async (e) => { console.log("no check card; panel:", await shadow("const p = r.querySelector('#panel'); return `hidden=${p.hidden} ${p.className}: ${p.innerText.replace(/\\s+/g, ' ')}`")); throw e; });
  console.log("check card:", await page.evaluate(() => document.querySelector("pointandyap-bar").shadowRoot.querySelector("#panel").innerText.replace(/\s+/g, " ")));
  if (process.env.NOT_YET) {
    // "Not yet": a new recording about the same item, then stop as before.
    console.log("not yet clicked:", await clickIn("[data-no]"));
    await sleep(1500);
    const b = await (await page.$(".card button")).boundingBox();
    await page.mouse.move(b.x + 30, b.y + 15, { steps: 8 });
    await sleep(2500);
    await press();
    await sleep(2500);
    console.log("follow-up sent");
    await browser.close();
    process.exit(0);
  }
  console.log("looks right clicked:", await clickIn("[data-ok]"));
  await sleep(1500);
  await clickIn("#list");
  await page.waitForFunction(() => /Confirmed/.test(document.querySelector("pointandyap-bar").shadowRoot.querySelector("#panel").innerText), { timeout: 10000 });
  await page.screenshot({ path: `${out}/live-6-confirmed.png` });
  console.log("confirmed in the panel");
}
console.log("page errors:", problems.length ? problems : "none");
await browser.close();
