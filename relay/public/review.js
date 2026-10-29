// The review page: shows the screenshots someone shared, records the guest pointing and talking (or typing), and sends
// it sealed to the sharer's Mac. Nothing leaves this page unencrypted; the link key never leaves the #fragment.
import { unb64url, b64, openTour, sealFeedback } from "/seal.js";

const $ = (id) => document.getElementById(id);
const id = location.pathname.split("/").pop();
const show = (el, on = true) => { $(el).hidden = !on; };
const REST_PX = 8, REST_S = 0.35, SAMPLE_HZ = 30, MAX_S = 600;

let tour, linkKey, current = 0, urls = [];
let rec = null;            // the recording in progress: {t0, samples, points, chunks, rate, ctx, stream}
let take = null;           // a finished recording waiting to be sent
let typed = { t0: 0, points: [] };

function fail(msg) { const e = $("error"); e.textContent = msg; e.hidden = false; }
function clearError() { $("error").hidden = true; }

async function load() {
  const k = new URLSearchParams(location.hash.slice(1)).get("k");
  if (!k) { $("title").textContent = "This link is missing its key"; $("lede").textContent = "Ask for the whole link: the part after # opens it."; return; }
  linkKey = unb64url(k);
  const res = await fetch(`/api/links/${id}/tour`, { cache: "no-store" });
  if (!res.ok) { $("title").textContent = "This link has expired or was taken back"; return; }
  try { tour = await openTour(new Uint8Array(await res.arrayBuffer()), linkKey, id); }
  catch { $("title").textContent = "This link does not open"; $("lede").textContent = "The key in it does not match. Ask for the link again."; return; }

  const who = tour.from || "The person who sent this";
  if (tour.invite) {
    // An invite: feedback is made in Point and Yap itself, pointing at anything on the guest's own screen.
    $("title").textContent = `${who} wants your feedback`;
    $("lede").textContent = "Show them, don't type: point at things on your screen and talk. Point and Yap sends each recording to them, and only they can read it.";
    $("inviteTo").textContent = tour.from || "them";
    $("openApp").href = `pointandyap://join?link=${encodeURIComponent(location.href)}`;
    show("invite");
    return;
  }
  $("title").textContent = tour.title || "Have a look";
  $("lede").textContent = `${who} wants your take on ${tour.frames.length === 1 ? "this screen" : `these ${tour.frames.length} screens`}. ` +
    `Point at things and say what you think. Only ${tour.from || "they"} will see it, not others with the link.`;
  urls = tour.frames.map((f) => URL.createObjectURL(new Blob([Uint8Array.from(atob(f.jpeg), (c) => c.charCodeAt(0))], { type: "image/jpeg" })));
  const strip = $("strip");
  tour.frames.forEach((f, i) => {
    const b = document.createElement("button");
    b.setAttribute("role", "tab");
    b.setAttribute("aria-label", `Screenshot ${i + 1}`);
    const img = document.createElement("img"); img.src = urls[i]; img.alt = "";
    b.append(img); b.onclick = () => select(i); strip.append(b);
  });
  show("strip", tour.frames.length > 1);
  try { $("name").value = localStorage.getItem("pay-name") || ""; } catch {}
  select(0);
  show("stage"); show("panel");
}

function select(i) {
  current = Math.max(0, Math.min(i, tour.frames.length - 1));
  $("shot").src = urls[current];
  [...$("strip").children].forEach((b, j) => b.setAttribute("aria-selected", String(j === current)));
  drawPins();
}

const frameName = () => tour.frames[current].name;
const now = () => (performance.now() - rec.t0) / 1000;

/** Pointer position on the screenshot, 0..1 on both axes. */
function norm(e) {
  const r = $("shot").getBoundingClientRect();
  return { x: Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)), y: Math.min(1, Math.max(0, (e.clientY - r.top) / r.height)), w: r.width, h: r.height };
}

function drawPins() {
  const pins = $("pins"); pins.replaceChildren();
  const list = rec ? rec.points : take ? take.points : typed.points;
  list.forEach((p, i) => {
    // Rests shorter than half a second are the pointer passing by, as on the Mac.
    if (p.f !== frameName() || (p.kind === "dwell" && p.end - p.t < 0.5)) return;
    const d = document.createElement("span"); d.className = "pin"; d.textContent = String(i + 1);
    d.style.left = `${p.x * 100}%`; d.style.top = `${p.y * 100}%`; pins.append(d);
  });
}

// MARK: Pointing

let anchor = null, lastSample = 0;
const shot = $("frame");
shot.addEventListener("pointermove", (e) => {
  if (!rec) return;
  const p = norm(e), t = now();
  if (t - lastSample >= 1 / SAMPLE_HZ) { rec.samples.push({ t: r3(t), f: frameName(), x: r4(p.x), y: r4(p.y), down: e.buttons !== 0 }); lastSample = t; }
  if (!anchor || anchor.f !== frameName() || Math.hypot((p.x - anchor.x) * p.w, (p.y - anchor.y) * p.h) > REST_PX) {
    if (rec.resting) { rec.resting.end = r3(t); rec.resting = null; drawPins(); }
    anchor = { x: p.x, y: p.y, t, f: frameName() };
  }
});
shot.addEventListener("pointerdown", (e) => {
  const p = norm(e);
  if (rec) { rec.points.push({ t: r3(now()), end: r3(now()), kind: "click", f: frameName(), x: r4(p.x), y: r4(p.y) }); drawPins(); return; }
  if (!$("typing").hidden) {
    // Typing: a click drops [n] into the text where the caret is, and the point is placed in time by that position.
    const ta = $("text"), n = typed.points.length + 1, at = ta.selectionStart ?? ta.value.length;
    const tag = `[${n}] `;
    ta.value = ta.value.slice(0, at) + tag + ta.value.slice(at);
    ta.selectionStart = ta.selectionEnd = at + tag.length;
    typed.points.push({ at, kind: "click", f: frameName(), x: r4(p.x), y: r4(p.y), t: 0, end: 0 });
    drawPins(); ta.focus();
  }
});
shot.addEventListener("pointerleave", () => { if (rec?.resting) { rec.resting.end = r3(now()); rec.resting = null; } anchor = null; });

// A rest is a point once the pointer has stayed put long enough, even with no more events.
setInterval(() => {
  if (!rec || !anchor || rec.resting) return;
  const t = now();
  if (t - anchor.t >= REST_S && anchor.f === frameName()) {
    rec.resting = { t: r3(anchor.t), end: r3(t), kind: "dwell", f: anchor.f, x: r4(anchor.x), y: r4(anchor.y) };
    rec.points.push(rec.resting);
  }
  if (rec.resting) rec.resting.end = r3(t);
}, 50);
setInterval(() => { if (rec?.resting) { rec.resting.end = r3(now()); drawPins(); } }, 200);

// MARK: Recording

async function start() {
  clearError();
  let stream;
  try { stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true } }); }
  catch { fail("The microphone is not allowed on this page. Allow it in the browser, or type instead."); return; }
  const ctx = new (window.AudioContext || window.webkitAudioContext)();
  const src = ctx.createMediaStreamSource(stream);
  const node = ctx.createScriptProcessor(4096, 1, 1);
  rec = { t0: performance.now(), samples: [], points: [], chunks: [], rate: ctx.sampleRate, ctx, stream, node, resting: null };
  node.onaudioprocess = (e) => { if (rec) rec.chunks.push(new Float32Array(e.inputBuffer.getChannelData(0))); };
  src.connect(node); node.connect(ctx.destination);
  anchor = null;
  shot.classList.add("on"); show("live"); show("ready", false); show("recording");
  rec.tick = setInterval(() => {
    const s = Math.floor(now()); $("clock").textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
    if (s >= MAX_S) stop();
  }, 250);
  drawPins();
}

function end() {
  clearInterval(rec.tick);
  rec.node.disconnect(); rec.stream.getTracks().forEach((t) => t.stop()); rec.ctx.close();
  shot.classList.remove("on"); show("live", false); show("recording", false);
}

function stop() {
  if (!rec) return;
  const duration = now();
  if (rec.resting) rec.resting.end = r3(duration);
  end();
  const points = rec.points.filter((p) => p.kind === "click" || p.end - p.t >= 0.5);
  take = { duration: r3(duration), samples: rec.samples, points, wav: wav(rec.chunks, rec.rate) };
  rec = null;
  $("summary").textContent = `${Math.round(take.duration)} s, ${points.length} point${points.length === 1 ? "" : "s"}`;
  show("review"); drawPins();
}

function cancel() { if (!rec) return; end(); rec = null; show("ready"); drawPins(); }

/** Mono 16 kHz 16-bit WAV, which the Mac's speech model reads as it is. */
function wav(chunks, rate) {
  const len = chunks.reduce((n, c) => n + c.length, 0), all = new Float32Array(len);
  let o = 0; for (const c of chunks) { all.set(c, o); o += c.length; }
  const out = 16000, n = Math.floor(len * out / rate), pcm = new Int16Array(n), step = rate / out;
  for (let i = 0; i < n; i++) {
    const a = Math.floor(i * step), b = Math.min(len, Math.floor((i + 1) * step));
    let s = 0; for (let j = a; j < b; j++) s += all[j];
    const v = b > a ? s / (b - a) : 0; pcm[i] = Math.max(-1, Math.min(1, v)) * 0x7fff;
  }
  const buf = new ArrayBuffer(44 + pcm.byteLength), d = new DataView(buf);
  const str = (off, s) => [...s].forEach((c, i) => d.setUint8(off + i, c.charCodeAt(0)));
  str(0, "RIFF"); d.setUint32(4, 36 + pcm.byteLength, true); str(8, "WAVE"); str(12, "fmt ");
  d.setUint32(16, 16, true); d.setUint16(20, 1, true); d.setUint16(22, 1, true); d.setUint32(24, out, true);
  d.setUint32(28, out * 2, true); d.setUint16(32, 2, true); d.setUint16(34, 16, true); str(36, "data"); d.setUint32(40, pcm.byteLength, true);
  new Int16Array(buf, 44).set(pcm);
  return new Uint8Array(buf);
}

// MARK: Sending

async function send(body) {
  clearError();
  const name = $("name").value.trim();
  if (!name) { fail("Add your name, so they know who it is from."); $("name").focus(); return false; }
  try { localStorage.setItem("pay-name", name); } catch {}
  const sealed = await sealFeedback({ v: 1, name, ...body }, tour.key, linkKey, id);
  const res = await fetch(`/api/links/${id}/feedback`, { method: "POST", body: sealed, headers: { "Content-Type": "application/octet-stream" } });
  if (!res.ok) { fail(res.status === 429 ? "This link is full for now. Try again later." : "Could not send. Try again."); return false; }
  $("sentText").textContent = `Sent privately to ${tour.from || "the person who shared this"}. Only their Mac can open it.`;
  show("sent"); return true;
}

async function sendTake() {
  $("send").disabled = true;
  const ok = await send({ duration: take.duration, samples: take.samples, points: take.points, audio: b64(take.wav) });
  $("send").disabled = false;
  if (ok) { show("review", false); take = null; drawPins(); }
}

async function sendText() {
  // The [n] tags come out of the text (the Mac puts its own markers back); each point is placed in time where its tag
  // sat in the text, so the Mac lines it up with the words around it.
  const raw = $("text").value, where = {};
  let text = "", last = 0;
  for (const m of raw.matchAll(/\[(\d+)\]\s?/g)) { text += raw.slice(last, m.index); where[m[1]] = text.length; last = m.index + m[0].length; }
  text = (text + raw.slice(last)).trim();
  if (!text) { fail("Write what should change first."); return; }
  const duration = Math.max(3, (performance.now() - typed.t0) / 1000);
  const points = typed.points.map((p, i) => {
    const t = r3(duration * Math.min(1, (where[i + 1] ?? text.length) / Math.max(1, text.length)));
    return { t, end: t, kind: p.kind, f: p.f, x: p.x, y: p.y };
  });
  $("sendText").disabled = true;
  const ok = await send({ duration: r3(duration), samples: [], points, text });
  $("sendText").disabled = false;
  if (ok) { show("typing", false); $("text").value = ""; typed.points = []; shot.classList.remove("typing"); drawPins(); }
}

$("start").onclick = start;
$("stop").onclick = stop;
$("cancel").onclick = cancel;
$("send").onclick = sendTake;
$("again").onclick = () => { take = null; show("review", false); show("ready"); drawPins(); };
$("typeMode").onclick = () => { show("ready", false); show("typing"); typed = { t0: performance.now(), points: [] }; shot.classList.add("typing"); $("text").focus(); drawPins(); };
$("talkMode").onclick = () => { show("typing", false); show("ready"); typed.points = []; shot.classList.remove("typing"); drawPins(); };
$("sendText").onclick = sendText;
$("more").onclick = () => { show("sent", false); show("ready"); };
document.addEventListener("keydown", (e) => {
  if (e.target.matches("input, textarea")) return;
  if (e.key === "Escape") cancel();
  if (e.key === "ArrowRight") select(current + 1);
  if (e.key === "ArrowLeft") select(current - 1);
});

const r3 = (v) => Math.round(v * 1000) / 1000, r4 = (v) => Math.round(v * 10000) / 10000;
load().catch(() => fail("Something went wrong opening this link."));
