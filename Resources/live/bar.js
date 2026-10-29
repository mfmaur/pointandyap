// Point and Yap's review bar. PointAndYap --live puts it into every page of an app shared from the owner's localhost,
// so whoever has the link uses the real, running app and points and talks on it. A recording carries what they said,
// the elements they rested on or clicked (with the source file when the framework says it), their page as it was, and
// the page's errors. Everyone in the link sees each other's cursors and the queue moving; when an agent finishes your
// request, hot reload has already changed your page, and you say "looks right" or "not yet".
(() => {
  if (window.top !== window || window.__pointandyap) return;
  window.__pointandyap = true;

  // MARK: The page's errors, from its first line on

  const errors = [];
  const clock = () => new Date().toTimeString().slice(0, 8);
  const note = (s) => { errors.push(`${clock()} ${String(s).replace(/\s+/g, " ").slice(0, 280)}`); if (errors.length > 40) errors.shift(); };
  const shortURL = (u) => { try { const x = new URL(u, location.href); return x.origin === location.origin ? x.pathname + x.search : x.href; } catch { return String(u); } };
  const fmt = (a) => {
    if (a instanceof Error) return `${a.name}: ${a.message}${a.stack ? ` (${(a.stack.split("\n").find((l) => /:\d+:\d+/.test(l)) || "").trim()})` : ""}`;
    if (typeof a === "object") { try { return JSON.stringify(a).slice(0, 200); } catch { return String(a); } }
    return String(a);
  };
  const consoleError = console.error.bind(console);
  console.error = (...a) => { note("console.error: " + a.map(fmt).join(" ")); consoleError(...a); };
  addEventListener("error", (e) => {
    if (e.target && e.target !== window && e.target.tagName) { const t = e.target; note(`could not load ${t.tagName.toLowerCase()} ${shortURL(t.src || t.href || "")}`); }
    else note(`${e.message}${e.filename ? ` at ${shortURL(e.filename)}:${e.lineno}` : ""}`);
  }, true);
  addEventListener("unhandledrejection", (e) => note(`unhandled rejection: ${fmt(e.reason)}`));
  const ours = (u) => String(u).includes("/__pay/");
  const realFetch = window.fetch;
  window.fetch = async function (input, init) {
    const url = typeof input === "string" ? input : input?.url || String(input);
    const method = (init?.method || input?.method || "GET").toUpperCase();
    if (ours(url)) return realFetch.apply(this, arguments);
    try {
      const r = await realFetch.apply(this, arguments);
      if (!r.ok) note(`${method} ${shortURL(url)} → ${r.status}`);
      return r;
    } catch (err) { note(`${method} ${shortURL(url)} failed: ${err?.message || err}`); throw err; }
  };
  const xopen = XMLHttpRequest.prototype.open, xsend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (m, u) { this.__pay = [String(m).toUpperCase(), u]; return xopen.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function () {
    const [m, u] = this.__pay || ["GET", ""];
    if (!ours(u)) this.addEventListener("loadend", () => { if (this.status === 0 || this.status >= 400) note(`${m} ${shortURL(u)} → ${this.status || "failed"}`); });
    return xsend.apply(this, arguments);
  };

  // MARK: State

  const store = { get: (k) => { try { return localStorage.getItem(k); } catch { return null; } }, set: (k, v) => { try { localStorage.setItem(k, v); } catch {} } };
  const S = {
    name: store.get("pay-name") || "", role: null, owner: "", privateMode: false, trusted: false, me: null,
    peers: [], items: [], rec: null, panel: false, lock: false, connected: false, small: store.get("pay-small") === "1",
    typing: null, toast: null, asking: null, agents: [], hover: null, welcomed: store.get("pay-welcomed") === "1",
  };
  const seen = new Map();   // item id → status last seen, to notice "done" on mine
  const REST_PX = 8, REST_S = 0.35, MAX_S = 600;

  // MARK: What is under the pointer

  let host, root;
  const isOurs = (e) => e && (e === host || (e.composedPath && e.composedPath().includes(host)));
  const at = (x, y) => {
    if (host) host.style.visibility = "hidden";
    const el = document.elementFromPoint(x, y);
    if (host) host.style.visibility = "";
    return el;
  };

  const roles = { BUTTON: "button", A: "link", SELECT: "combobox", TEXTAREA: "textbox", IMG: "img", NAV: "navigation", LI: "listitem",
    H1: "heading", H2: "heading", H3: "heading", H4: "heading", H5: "heading", H6: "heading", TABLE: "table", TR: "row", TD: "cell", TH: "columnheader",
    FORM: "form", DIALOG: "dialog", LABEL: "label", SUMMARY: "button", HEADER: "banner", FOOTER: "contentinfo", MAIN: "main", ASIDE: "complementary" };
  function role(e) {
    if (e.getAttribute("role")) return e.getAttribute("role");
    if (e.tagName === "INPUT") return { checkbox: "checkbox", radio: "radio", range: "slider", button: "button", submit: "button", search: "searchbox" }[e.type] || "textbox";
    if (e.tagName === "A" && !e.hasAttribute("href")) return null;
    return roles[e.tagName] || null;
  }

  const hashed = (c) => /^(css|sc|jsx|emotion|svelte|styles?_|_)[-_]?[a-z0-9]{4,}|^[a-z0-9]{6,}$|__[a-z0-9]{5}$/i.test(c);
  function label(e) {
    let s = e.tagName.toLowerCase();
    if (e.id && !/\d{4,}|:/.test(e.id)) return s + "#" + e.id;
    const c = [...e.classList].find((c) => !hashed(c));
    return c ? `${s}.${c}` : s;
  }

  function selector(el) {
    if (!el || el.nodeType !== 1) return null;
    const parts = [];
    for (let e = el; e && e.nodeType === 1 && e !== document.documentElement && parts.length < 8; e = e.parentElement) {
      if (e.id && !/\d{4,}|:/.test(e.id) && document.querySelectorAll("#" + CSS.escape(e.id)).length === 1) { parts.unshift("#" + CSS.escape(e.id)); return parts.join(" > "); }
      const tid = e.getAttribute("data-testid") || e.getAttribute("data-test-id") || e.getAttribute("data-cy");
      if (tid) {
        const attr = e.hasAttribute("data-testid") ? "data-testid" : e.hasAttribute("data-test-id") ? "data-test-id" : "data-cy";
        const s = `[${attr}="${CSS.escape(tid)}"]`;
        if (document.querySelectorAll(s).length === 1) { parts.unshift(s); return parts.join(" > "); }
      }
      let s = e.tagName.toLowerCase();
      const p = e.parentElement;
      if (p) { const same = [...p.children].filter((c) => c.tagName === e.tagName); if (same.length > 1) s += `:nth-of-type(${same.indexOf(e) + 1})`; }
      parts.unshift(s);
    }
    return parts.join(" > ");
  }

  const visible = (e) => (e.innerText || e.textContent || "").replace(/\s+/g, " ").trim().slice(0, 120) || null;

  // Component names that say nothing about the app.
  const plumbing = /^(Provider|Consumer|Context|ForwardRef|Memo|Suspense|Fragment|StrictMode|Profiler|Router|Routes|Route|RenderedRoute|Outlet|ErrorBoundary|HotReload|AppRouter|Router|InnerLayoutRouter|OuterLayoutRouter|RedirectBoundary|RedirectErrorBoundary|NotFoundBoundary|NotFoundErrorBoundary|HTTPAccessFallbackBoundary|HTTPAccessFallbackErrorBoundary|LoadingBoundary|ScrollAndFocusHandler|InnerScrollAndFocusHandler|RenderFromTemplateContext|ServerRoot|Root|App(Dev)?Overlay|ReactDevOverlay|DevRootHTTPAccessFallbackBoundary|PathnameContextProviderAdapter|Head|Anonymous|Unknown)$/;
  const cname = (t) => t && (t.displayName || t.name || (t.render && (t.render.displayName || t.render.name)) || (t.type && cname(t.type)));

  /** Where the framework says an element is drawn: source file and line, and the components around it. */
  function framework(el) {
    let src = null, stack = null;
    const comps = [];
    for (let e = el, i = 0; e && e.nodeType === 1 && i < 6 && !src; e = e.parentElement, i++) {
      const a = e.getAttribute("data-pay-src") || e.getAttribute("data-insp-path") || e.getAttribute("data-v-inspector") || e.getAttribute("data-source-loc");
      if (a) src = a.split(":").slice(0, 3).join(":");
      else if (e.getAttribute("data-inspector-relative-path")) src = `${e.getAttribute("data-inspector-relative-path")}:${e.getAttribute("data-inspector-line") || 1}`;
      else if (e.__svelte_meta?.loc) { const l = e.__svelte_meta.loc; src = `${l.file}:${l.line}:${(l.column ?? 0) + 1}`; }
    }
    // React: the element's fiber knows its JSX (React 18: _debugSource; 19: the stack where it was made).
    let fe = el;
    while (fe && fe.nodeType === 1 && !Object.keys(fe).some((k) => k.startsWith("__reactFiber$"))) fe = fe.parentElement;
    const key = fe && Object.keys(fe).find((k) => k.startsWith("__reactFiber$"));
    if (key) {
      const f = fe[key];
      if (!src && f._debugSource) src = `${f._debugSource.fileName}:${f._debugSource.lineNumber}:${f._debugSource.columnNumber ?? 1}`;
      if (!src && f._debugStack) stack = String(f._debugStack.stack || f._debugStack);
      for (let p = f.return; p && comps.length < 12; p = p.return) {
        if (typeof p.type === "function" || (p.type && typeof p.type === "object")) {
          const n = cname(p.type);
          if (n && !plumbing.test(n) && /^[A-Z]/.test(n) && comps[0] !== n) comps.unshift(n);
        }
      }
    }
    // Vue 3, in development: the component's file.
    let v = null;
    for (let e = el; e && !v; e = e.parentElement) v = e.__vueParentComponent || null;
    if (v) {
      if (!src && v.type?.__file) src = v.type.__file;
      for (let c = v; c && comps.length < 12; c = c.parent) { const n = c.type?.name || c.type?.__name; if (n) comps.unshift(n); }
    }
    return { src: src && clean(src), stack, comps: comps.slice(-6) };
  }

  /** A path as an agent finds it in the project: no origin, query, or bundler prefix. */
  function clean(p) {
    let s = String(p).replace(/^webpack(-internal)?:\/\/\/?(\([^)]*\)\/)?[^/]*\/\.\//, "").replace(/^webpack:\/\/[^/]*\//, "");
    try { if (/^https?:/.test(s)) { const u = new URL(s); s = u.pathname + (u.hash || ""); } } catch {}
    s = s.replace(/\?[^:]*(?=:\d|$)/, "").replace(/^\/@fs/, "");
    if (!/^\/(Users|home|var|private|opt|Volumes)\//.test(s)) s = s.replace(/^\/+/, "");
    return s;
  }

  // React 19 keeps the stack where an element was made; the line in it is of the bundled module, so it is mapped
  // back to the source with the module's own source map, as the browser's devtools do.
  const lib = (u) => /\/node_modules\/|\/\.vite\/deps\/|react-dom|react\.development|jsx-dev-runtime|jsx-runtime|\/__pay\/|\/_next\/static\/chunks\/(webpack|main|framework|react|polyfill)|next\/dist\//.test(u);
  function firstFrame(stack) {
    for (const l of String(stack).split("\n")) {
      const m = l.match(/((?:https?|webpack-internal|file):\/\/[^\s()]+?):(\d+):(\d+)\)?\s*$/);
      if (m && !lib(m[1])) return { url: m[1], line: +m[2], col: +m[3] };
    }
    return null;
  }
  const maps = new Map();
  const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  function vlq(s) {
    const out = []; let shift = 0, val = 0;
    for (const ch of s) {
      let d = B64.indexOf(ch); const more = d & 32; d &= 31; val += d << shift;
      if (more) shift += 5; else { out.push(val & 1 ? -(val >> 1) : val >> 1); val = 0; shift = 0; }
    }
    return out;
  }
  function decode(mappings) {
    const lines = []; let src = 0, sl = 0, sc = 0;
    for (const line of mappings.split(";")) {
      const segs = []; let gc = 0;
      if (line) for (const seg of line.split(",")) {
        const v = vlq(seg); if (!v.length) continue;
        gc += v[0];
        if (v.length >= 4) { src += v[1]; sl += v[2]; sc += v[3]; segs.push([gc, src, sl, sc]); }
      }
      lines.push(segs);
    }
    return lines;
  }
  async function sourceMap(url) {
    try {
      const js = await (await realFetch(url)).text();
      const refs = [...js.matchAll(/\/\/[#@] sourceMappingURL=(\S+)/g)];
      if (!refs.length) return null;
      const ref = refs[refs.length - 1][1];
      let map;
      if (ref.startsWith("data:")) {
        const raw = atob(ref.slice(ref.indexOf(",") + 1));
        map = JSON.parse(new TextDecoder().decode(Uint8Array.from(raw, (c) => c.charCodeAt(0))));
      } else map = await (await realFetch(new URL(ref, url))).json();
      const modulePath = new URL(url).pathname;
      const sources = map.sources.map((s) => {
        const full = (map.sourceRoot || "") + s;
        if (/^\/(Users|home|var|private|opt|Volumes)\//.test(full)) {
          // An absolute path on the owner's Mac: as the project sees it, when the module's URL ends the same way.
          return full.endsWith(modulePath) ? modulePath.slice(1) : full;
        }
        try { return clean(new URL(full, url).href); } catch { return clean(full); }
      });
      return { sources, lines: decode(map.mappings) };
    } catch { return null; }
  }
  async function resolve(stack) {
    const f = firstFrame(stack);
    if (!f) return null;
    if (f.url.startsWith("webpack-internal:")) return clean(f.url);   // the file; its line numbers are the bundle's
    if (!maps.has(f.url)) maps.set(f.url, sourceMap(f.url));
    const m = await maps.get(f.url);
    if (!m) return `${clean(f.url)}:${f.line}`;
    const segs = m.lines[f.line - 1] || [];
    let best = null;
    for (const s of segs) if (s[0] <= f.col - 1) best = s;
    best = best || segs[0];
    return best ? `${m.sources[best[1]]}:${best[2] + 1}:${best[3] + 1}` : `${clean(f.url)}:${f.line}`;
  }

  /** The element worth naming at a point: the control around a tapped icon or label text. */
  function pick(x, y) {
    let el = at(x, y);
    if (!el || isOurs(el) || el === document.documentElement || el === document.body) return null;
    const ctl = el.closest("button, a[href], input, select, textarea, summary, label, [role], [data-testid]");
    if (ctl && ctl !== document.body) {
      let d = 0; for (let e = el; e && e !== ctl; e = e.parentElement) d++;
      if (d <= 4) el = ctl;
    }
    return backdrop(el) ? null : el;
  }
  /** A wrapper that fills most of the window: resting on empty space, not on a thing. */
  function backdrop(el) {
    const r = el.getBoundingClientRect();
    return r.width * r.height > 0.6 * innerWidth * innerHeight && !el.closest("button, a[href], input, select, textarea, img, video, canvas, [role]");
  }

  /** How the bar names an element to the person pointing: what they will see in the request. */
  function nameOf(el) {
    const r = role(el), t = (el.getAttribute("aria-label") || visible(el) || el.getAttribute("alt") || el.getAttribute("placeholder") || "").slice(0, 40);
    return `${r || el.tagName.toLowerCase()}${t ? ` “${t}”` : ""}`;
  }

  function describe(x, y) {
    const el = pick(x, y);
    return el ? describeEl(el) : null;
  }
  function describeEl(el) {
    const r = el.getBoundingClientRect();
    const fw = framework(el);
    const out = {
      tag: el.tagName.toLowerCase(), role: role(el), text: visible(el),
      label: el.getAttribute("aria-label") || el.getAttribute("title") || el.getAttribute("alt") || el.getAttribute("placeholder") || null,
      value: el.tagName === "INPUT" && el.type !== "password" ? el.value || null : el.tagName === "SELECT" ? el.selectedOptions[0]?.text || null : null,
      id: el.id || null, testid: el.getAttribute("data-testid") || null,
      rect: { x: r.left, y: r.top, w: r.width, h: r.height }, sel: selector(el), comp: fw.comps, src: fw.src,
      path: (() => { const p = []; for (let e = el.parentElement; e && e !== document.documentElement && p.length < 6; e = e.parentElement) p.unshift(label(e)); return p; })(),
    };
    if (out.text && out.text === out.label) out.label = null;
    if (fw.stack) Object.defineProperty(out, "stack", { value: fw.stack, enumerable: false });
    Object.defineProperty(out, "node", { value: el, enumerable: false });   // for the marks while recording
    return out;
  }

  // MARK: The page as it is, to be drawn again on the owner's Mac

  let dirty = true, lastSnap = null, snapN = 0;
  new MutationObserver(() => { dirty = true; }).observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
  addEventListener("scroll", () => { dirty = true; }, true);
  addEventListener("input", () => { dirty = true; }, true);
  addEventListener("resize", () => { dirty = true; });

  function serialize() {
    const doc = document.documentElement, clone = doc.cloneNode(true);
    const os = [doc, ...doc.querySelectorAll("*")], cs = [clone, ...clone.querySelectorAll("*")];
    for (let i = 0; i < os.length && i < cs.length; i++) {
      const o = os[i], c = cs[i], tag = o.tagName;
      if (o === host || tag === "SCRIPT" || tag === "NOSCRIPT" || (tag === "LINK" && /preload|prefetch/.test(o.rel))) { c.remove(); continue; }
      for (const a of [...c.attributes]) if (/^on/i.test(a.name)) c.removeAttribute(a.name);
      if (tag === "INPUT") {
        if (o.type === "checkbox" || o.type === "radio") o.checked ? c.setAttribute("checked", "") : c.removeAttribute("checked");
        else c.setAttribute("value", o.type === "password" ? (o.value ? "••••••" : "") : o.value);
      } else if (tag === "TEXTAREA") c.textContent = o.value;
      else if (tag === "SELECT") [...c.options].forEach((op, j) => (j === o.selectedIndex ? op.setAttribute("selected", "") : op.removeAttribute("selected")));
      else if (tag === "STYLE" && !o.textContent.trim()) {
        // Styles put in with insertRule (CSS-in-JS in production) are not in the text.
        try { c.textContent = [...o.sheet.cssRules].map((r) => r.cssText).join("\n"); } catch {}
      } else if (tag === "CANVAS") {
        try { const img = document.createElement("img"); img.src = o.toDataURL(); img.setAttribute("style", c.getAttribute("style") || ""); img.width = o.clientWidth; img.height = o.clientHeight; c.replaceWith(img); } catch {}
      }
      if ((o.scrollTop || o.scrollLeft) && o !== doc && o !== document.body) c.setAttribute("data-pay-scroll", `${o.scrollLeft},${o.scrollTop}`);
      if (o.shadowRoot && o.shadowRoot.mode === "open" && o !== host) {
        const t = document.createElement("template");
        t.setAttribute("shadowrootmode", "open");
        let css = "";
        try { css = (o.shadowRoot.adoptedStyleSheets || []).map((s) => [...s.cssRules].map((r) => r.cssText).join("\n")).join("\n"); } catch {}
        t.innerHTML = (css ? `<style>${css}</style>` : "") + o.shadowRoot.innerHTML;
        c.prepend(t);
      }
    }
    try {
      const adopted = (document.adoptedStyleSheets || []).map((s) => [...s.cssRules].map((r) => r.cssText).join("\n")).join("\n");
      if (adopted) { const st = document.createElement("style"); st.textContent = adopted; clone.querySelector("head")?.append(st); }
    } catch {}
    return "<!DOCTYPE html>" + clone.outerHTML;
  }

  /** The page now, or the last one if nothing has changed since. */
  function snapshot(t) {
    if (!dirty && lastSnap && lastSnap.sx === scrollX && lastSnap.sy === scrollY && lastSnap.w === innerWidth) return lastSnap;
    let html;
    try { html = serialize(); } catch { return null; }
    if (html.length > 6e6) return null;
    dirty = false;
    lastSnap = { id: `s${++snapN}`, html, w: innerWidth, h: innerHeight, sx: scrollX, sy: scrollY, t, origin: location.origin };
    S.rec?.snaps.set(lastSnap.id, lastSnap);
    return lastSnap;
  }

  // MARK: Recording

  const now = () => (performance.now() - S.rec.t0) / 1000;
  const r3 = (v) => Math.round(v * 1000) / 1000;

  function point(kind, x, y) {
    const t = now(), el = describe(x, y);
    if (!el) return null;
    const snap = snapshot(t);
    if (snap) S.rec.snaps.set(snap.id, snap);
    const p = { t: r3(t), end: r3(t), kind, x: Math.round(x), y: Math.round(y), snap: snap?.id || null, el };
    S.rec.points.push(p);
    return p;
  }

  let anchor = null, resting = null, lastPointer = null;
  addEventListener("pointermove", (e) => {
    if (e.pointerType !== "touch") lastPointer = isOurs(e.target) ? null : { x: e.clientX, y: e.clientY };
    if (S.rec && isOurs(e.target)) { if (resting) { resting.end = r3(now()); resting = null; } anchor = null; }
    if ((!S.rec && !S.typing) || e.pointerType === "touch" || isOurs(e.target)) { if (S.hover) S.hover = null; return; }
    S.hover = pick(e.clientX, e.clientY);
    if (!S.rec) return;
    if (!anchor || Math.hypot(e.clientX - anchor.x, e.clientY - anchor.y) > REST_PX) {
      if (resting) { resting.end = r3(now()); resting = null; }
      anchor = { x: e.clientX, y: e.clientY, t: now() };
    }
  }, true);
  addEventListener("pointerdown", (e) => {
    if ((S.rec || S.typing) && e.altKey && e.button === 0 && !isOurs(e)) { e.preventDefault(); e.stopImmediatePropagation(); lastAlt = 0; areaFrom(e); return; }
    if (!S.rec || isOurs(e)) return;
    // Before the app reacts to it: the snapshot shows what they pressed on. The click itself goes on to the app.
    if (resting) { resting.end = r3(now()); resting = null; }
    point("click", e.clientX, e.clientY);
    anchor = null;
  }, true);
  setInterval(() => {
    if (!S.rec) return;
    if (anchor && !resting && now() - anchor.t >= REST_S) { resting = point("dwell", anchor.x, anchor.y); if (resting) resting.t = r3(anchor.t); }
    if (resting) resting.end = r3(now());
  }, 50);

  // A dragged box: the area is what they point at, named by the smallest element around it.
  function pointArea(r) {
    const pts = S.rec?.points || S.typing?.points;
    if (!pts) return;
    let el = at(r.x + r.w / 2, r.y + r.h / 2);
    for (; el && el !== document.body; el = el.parentElement) {
      const b = el.getBoundingClientRect();
      if (b.left <= r.x + 2 && b.top <= r.y + 2 && b.right >= r.x + r.w - 2 && b.bottom >= r.y + r.h - 2) break;
    }
    const d = describeEl(el || document.body);
    d.rect = { x: r.x, y: r.y, w: r.w, h: r.h };
    const rec = S.rec || { t0: S.typing.t0, points: [], snaps: new Map() }, typing = !S.rec;
    if (typing) S.rec = rec;   // for snapshot()
    const t = r3((performance.now() - rec.t0) / 1000);
    dirty = true;
    const snap = snapshot(t);
    if (typing) { S.rec = null; S.typing.snaps = S.typing.snaps || new Map(); if (snap) S.typing.snaps.set(snap.id, snap); }
    const p = { t, end: t, kind: "click", x: Math.round(r.x + r.w / 2), y: Math.round(r.y + r.h / 2), snap: snap?.id || null, el: d };
    Object.defineProperty(p, "box", { value: { x: r.x + scrollX, y: r.y + scrollY, w: r.w, h: r.h }, enumerable: false });
    pts.push(p);
  }

  /** Takes back the n-th mark: everything that pointed at that element (or that area) no longer counts. */
  function unmark(n) {
    const pts = S.rec?.points || S.typing?.points, gone = pointed()[n - 1];
    if (!pts || !gone) return;
    const key = markKey(gone);
    for (let i = pts.length - 1; i >= 0; i--) if (markKey(pts[i]) === key) { if (pts[i] === resting) resting = null; pts.splice(i, 1); }
    anchor = null;   // or resting there a moment longer would put it straight back
    render();
  }

  async function start(followUp = null) {
    if (S.rec) return;
    if (!S.name && S.role !== "owner") { S.asking = { ...S.asking, then: () => start(followUp) }; S.panel = true; render(); return; }
    let stream;
    try { stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true } }); }
    catch { toast("The microphone is not allowed here. You can type instead."); S.typing = { t0: performance.now(), points: [], followUp }; S.panel = true; render(); return; }
    const ctx = new (window.AudioContext || window.webkitAudioContext)();
    ctx.resume?.();
    const src = ctx.createMediaStreamSource(stream), node = ctx.createScriptProcessor(4096, 1, 1);
    S.rec = { t0: performance.now(), points: [], snaps: new Map(), chunks: [], rate: ctx.sampleRate, ctx, stream, node, followUp, lock: S.lock || S.privateMode };
    node.onaudioprocess = (e) => { if (S.rec) S.rec.chunks.push(new Float32Array(e.inputBuffer.getChannelData(0))); };
    src.connect(node); node.connect(ctx.destination);
    // Already resting on something when it starts: that counts as pointing at it.
    anchor = lastPointer ? { ...lastPointer, t: 0 } : null; resting = null; dirty = true;
    if (lastPointer) S.hover = pick(lastPointer.x, lastPointer.y);
    snapshot(0);
    send({ t: "talking", on: true });
    S.rec.tick = setInterval(() => { render(); if (now() >= MAX_S) stop(); }, 500);
    render();
  }

  function areaMode(on) {
    S.area = on;
    const ov = root.querySelector("#area");
    ov.hidden = !on; ov.firstChild.hidden = true;
    render();
  }
  let areaFrom = () => {};
  function wireArea() {
    const ov = root.querySelector("#area"), box = ov.firstChild;
    let from = null;
    areaFrom = (e) => { areaMode(true); from = { x: e.clientX, y: e.clientY }; };
    const rect = (e) => ({ x: Math.min(from.x, e.clientX), y: Math.min(from.y, e.clientY), w: Math.abs(e.clientX - from.x), h: Math.abs(e.clientY - from.y) });
    ov.addEventListener("pointerdown", (e) => { from = { x: e.clientX, y: e.clientY }; ov.setPointerCapture(e.pointerId); e.preventDefault(); });
    ov.addEventListener("pointermove", (e) => {
      if (!from) return;
      const r = rect(e);
      box.hidden = false;
      box.style.transform = `translate(${r.x}px, ${r.y}px)`; box.style.width = `${r.w}px`; box.style.height = `${r.h}px`;
    });
    ov.addEventListener("pointerup", (e) => {
      if (!from) return;
      const r = rect(e);
      from = null;
      if (r.w >= 8 && r.h >= 8) pointArea(r);
      areaMode(false);
    });
  }

  function end() {
    const r = S.rec;
    clearInterval(r.tick);
    r.node.disconnect(); r.stream.getTracks().forEach((t) => t.stop()); r.ctx.close();
    send({ t: "talking", on: false });
  }

  function cancel() { if (!S.rec) return; end(); S.rec = null; areaMode(false); }

  async function stop() {
    if (!S.rec) return;
    const r = S.rec, duration = now();
    if (resting) resting.end = r3(duration);
    end();
    S.rec = null; resting = null; anchor = null;
    if (S.area) areaMode(false);
    const points = r.points.filter((p) => p.kind === "click" || p.end - p.t >= 0.5);
    render();
    await upload({ duration: r3(duration), points, snaps: r.snaps, audio: b64(wav(r.chunks, r.rate)), followUp: r.followUp, private: r.lock });
  }

  async function upload({ duration, points, snaps, audio, text, followUp, private: priv }) {
    toast("Sending…", 0);
    // Source lines a framework keeps only as a stack are looked up now (a second at most).
    await Promise.race([
      Promise.all(points.map(async (p) => { if (!p.el?.src && p.el?.stack) p.el.src = await resolve(p.el.stack); })),
      new Promise((ok) => setTimeout(ok, 1500)),
    ]);
    const used = new Set(points.map((p) => p.snap).filter(Boolean));
    const first = points.find((p) => p.el?.sel);
    const body = {
      v: 1, name: S.name || S.owner || "Guest", duration, audio, text, followUp, private: !!priv, points,
      snaps: [...snaps.values()].filter((s) => used.has(s.id)),
      page: { url: location.href, title: document.title, w: innerWidth, h: innerHeight, dpr: devicePixelRatio, browser: browser(), errors: errors.slice(-12) },
      anchor: first ? { path: location.pathname, sel: first.el.sel, rx: rel(first).rx, ry: rel(first).ry } : { path: location.pathname },
    };
    try {
      const res = await realFetch("/__pay/api/rec", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
      if (!res.ok) throw new Error(String(res.status));
      toast(S.role === "owner" ? "Sent to your queue" : `Sent to ${S.owner || "them"}. You'll see it move below.`);
      S.panel = true; render();
    } catch {
      toast("Could not send. Is the link still live?");
    }
  }
  const rel = (p) => { const r = p.el.rect; return { rx: r.w ? Math.round(((p.x - r.x) / r.w) * 1000) / 1000 : 0.5, ry: r.h ? Math.round(((p.y - r.y) / r.h) * 1000) / 1000 : 0.5 }; };

  function browser() {
    const u = navigator.userAgent;
    const b = /Edg\//.test(u) ? "Edge" : /Firefox\//.test(u) ? "Firefox" : /Chrome\//.test(u) ? "Chrome" : /Safari\//.test(u) ? "Safari" : "a browser";
    const os = /iPhone/.test(u) ? "iPhone" : /iPad/.test(u) ? "iPad" : /Android/.test(u) ? "Android" : /Mac OS X/.test(u) ? "macOS" : /Windows/.test(u) ? "Windows" : /Linux/.test(u) ? "Linux" : "";
    return os ? `${b} on ${os}` : b;
  }

  /** Mono 16 kHz 16-bit WAV, which the Mac's speech model reads as it is. */
  function wav(chunks, rate) {
    const len = chunks.reduce((n, c) => n + c.length, 0), all = new Float32Array(len);
    let o = 0; for (const c of chunks) { all.set(c, o); o += c.length; }
    const out = 16000, n = Math.floor((len * out) / rate), pcm = new Int16Array(n), step = rate / out;
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
  function b64(bytes) { let s = ""; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000)); return btoa(s); }

  // Typing instead: what they click while the box is open is what they point at.
  addEventListener("pointerdown", (e) => {
    if (!S.typing || S.rec || isOurs(e)) return;
    const t = (performance.now() - S.typing.t0) / 1000, el = describe(e.clientX, e.clientY);
    if (!el) return;
    S.rec = { t0: S.typing.t0, points: [], snaps: new Map() };   // for snapshot()
    dirty = true;
    const snap = snapshot(t);
    S.typing.snaps = S.typing.snaps || new Map();
    if (snap) S.typing.snaps.set(snap.id, snap);
    S.typing.points.push({ t: r3(t), end: r3(t), kind: "click", x: Math.round(e.clientX), y: Math.round(e.clientY), snap: snap?.id || null, el });
    S.rec = null;
    render();
  }, true);

  async function sendTyped() {
    const box = root.querySelector("#text"), text = box?.value.trim();
    if (!text) { toast("Write what should change first."); return; }
    const ty = S.typing, duration = Math.max(3, (performance.now() - ty.t0) / 1000);
    S.typing = null; render();
    await upload({ duration: r3(duration), points: ty.points, snaps: ty.snaps || new Map(), text, followUp: ty.followUp, private: S.lock || S.privateMode });
  }

  // ⌥ twice (Alt on Windows) starts and stops, as Control twice does in the Mac app; Esc cancels.
  let lastAlt = 0, other = false;
  addEventListener("keydown", (e) => {
    if (e.key === "Escape" && S.area) { areaMode(false); return; }
    if (e.key === "Escape" && S.rec) { cancel(); return; }
    if (e.key !== "Alt") { other = true; return; }
    if (e.repeat) return;
    const t = performance.now();
    if (!other && t - lastAlt < 450) { lastAlt = 0; S.rec ? stop() : start(); }
    else lastAlt = t;
    other = false;
  }, true);

  // MARK: The room

  let ws = null, wait = 500;
  function connect() {
    ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/__pay/ws`);
    ws.onopen = () => { S.connected = true; wait = 500; if (S.name) send({ t: "hello", name: S.name }); render(); };
    ws.onclose = () => { S.connected = false; render(); if (!S.ended) setTimeout(connect, (wait = Math.min(wait * 2, 8000))); };
    ws.onmessage = (m) => { let msg; try { msg = JSON.parse(m.data); } catch { return; } on(msg); };
  }
  const send = (o) => { if (ws && ws.readyState === 1) ws.send(JSON.stringify(o)); };

  function on(msg) {
    if (msg.t === "welcome") {
      S.me = msg.you.id; S.role = msg.you.role; S.owner = msg.owner; S.privateMode = msg.private; S.trusted = msg.trusted;
      S.link = msg.link || ""; S.straight = !!msg.settings?.trusted;
      if (S.role === "owner") { S.name = msg.owner; send({ t: "hello", name: msg.owner }); }
      else if (!S.name && !S.welcomed) { S.welcomed = true; store.set("pay-welcomed", "1"); S.asking = { welcome: true }; S.panel = true; }
    } else if (msg.t === "settings") { S.privateMode = msg.private; S.trusted = msg.trusted; S.straight = !!msg.settings?.trusted; }
    else if (msg.t === "ended") { S.ended = true; if (S.rec) cancel(); S.typing = null; S.panel = false; S.asking = null; }
    else if (msg.t === "peers") S.peers = msg.peers;
    else if (msg.t === "cursor") { cursors.set(msg.id, { ...msg, at: performance.now() }); return; }
    else if (msg.t === "items") {
      // The list first: a toast below redraws, and the bar must already show what this message says.
      S.agents = msg.agents || [];
      S.items = msg.items;
      let said = null;
      for (const it of msg.items) {
        const before = seen.get(it.id);
        seen.set(it.id, it.status);
        if (!it.mine || !before || before === it.status) continue;
        if (before === "triage" && it.status === "open") said ||= `${S.owner} accepted it.${S.agents.length ? ` ${S.agents[0]} will pick it up.` : ""}`;
        else if (it.status === "in_progress") said ||= `${it.by || "The agent"} is working on it`;
        else if (it.status === "done" && !it.confirmed) {
          // A small card, not the list: the page itself is what they need to look at, so what they pointed at is
          // brought into view and its pin flashes. The first one first, when several are done at once.
          if (!msg.items.some((x) => x.id === S.check && x.status === "done" && !x.confirmed)) S.check = it.id;
          S.panel = false;
          chime();
          const sel = it.anchor?.path === location.pathname && it.anchor.sel;
          try { if (sel) document.querySelector(sel)?.scrollIntoView({ block: "center", behavior: "smooth" }); } catch {}
          S.flash = it.id; setTimeout(() => { S.flash = null; }, 4000);
        }
      }
      if (said) toast(said);
    }
    render();
  }

  function chime() {
    try {
      const c = new (window.AudioContext || window.webkitAudioContext)(), o = c.createOscillator(), g = c.createGain();
      o.frequency.value = 880; g.gain.setValueAtTime(0.0001, c.currentTime); g.gain.exponentialRampToValueAtTime(0.15, c.currentTime + 0.02);
      g.gain.exponentialRampToValueAtTime(0.0001, c.currentTime + 0.35); o.connect(g); g.connect(c.destination); o.start(); o.stop(c.currentTime + 0.4);
    } catch {}
  }

  // Others' cursors, placed on the same element as on their screen (screens differ), else at the same spot.
  const cursors = new Map();
  let lastMove = 0, lastSent = null, trailing = null;
  addEventListener("pointermove", (e) => {
    if (e.pointerType === "touch" || isOurs(e.target)) return;
    const t = performance.now();
    clearTimeout(trailing);
    // At most every 60 ms, and always the last position, so others see where it stopped.
    if (t - lastMove < 60) { const { clientX, clientY } = e; trailing = setTimeout(() => moved(clientX, clientY), 70); return; }
    moved(e.clientX, e.clientY);
  }, true);
  function moved(cx, cy) {
    lastMove = performance.now();
    const e = { clientX: cx, clientY: cy };
    const el = at(e.clientX, e.clientY);
    if (!el) return;
    const r = el.getBoundingClientRect();
    const sel = el === lastSent?.el ? lastSent.sel : selector(el);
    lastSent = { el, sel };
    send({ t: "cursor", path: location.pathname, sel, rx: r.width ? (e.clientX - r.left) / r.width : 0, ry: r.height ? (e.clientY - r.top) / r.height : 0,
      x: e.clientX + scrollX, y: e.clientY + scrollY, vw: innerWidth, vh: innerHeight });
  }
  document.addEventListener("mouseleave", () => send({ t: "cursor", gone: true }));

  const found = new Map();
  function place(c) {
    let el = found.get(c.sel);
    if (!el || !el.isConnected) { try { el = c.sel ? document.querySelector(c.sel) : null; } catch { el = null; } found.set(c.sel, el); }
    if (el) { const r = el.getBoundingClientRect(); if (r.width || r.height) return [r.left + c.rx * r.width, r.top + c.ry * r.height]; }
    return [c.x * (innerWidth / (c.vw || innerWidth)) - scrollX, c.y - scrollY];
  }
  function drawCursors() {
    const layer = root?.querySelector("#cursors");
    if (layer) {
      const t = performance.now(), keep = new Set();
      for (const [id, c] of cursors) {
        if (c.gone || t - c.at > 10000 || c.path !== location.pathname) continue;
        keep.add(id);
        let d = layer.querySelector(`[data-id="${id}"]`);
        if (!d) {
          d = document.createElement("div"); d.className = "cursor"; d.dataset.id = id;
          d.innerHTML = `<svg width="18" height="20" viewBox="0 0 18 20"><path d="M1 1l6.5 17 2.6-7.2L17 8.5z" fill="${c.color}" stroke="#fff" stroke-width="1.5" stroke-linejoin="round"/></svg><span></span>`;
          layer.append(d);
        }
        const [x, y] = place(c);
        d.style.transform = `translate(${x}px, ${y}px)`;
        const span = d.querySelector("span"); span.textContent = c.name; span.style.background = c.color;
        const talking = S.peers.find((p) => p.id === id)?.talking;
        d.classList.toggle("talking", !!talking);
      }
      for (const d of [...layer.children]) if (!keep.has(d.dataset.id)) d.remove();
      drawPins();
      drawMarks();
    }
    requestAnimationFrame(drawCursors);
  }

  // While recording (or typing): a box on what is under the pointer, and a numbered mark on each thing pointed at so
  // far, as the request will name them.
  const counted = (p) => p.kind === "click" || p.end - p.t >= 0.5;
  const markKey = (p) => p.box || p.el?.node;
  function pointed() {
    const pts = S.rec?.points || S.typing?.points || [];
    const out = [];
    for (const p of pts) if (counted(p) && markKey(p) && !out.some((q) => markKey(q) === markKey(p))) out.push(p);
    return out;
  }
  function drawMarks() {
    const layer = root.querySelector("#marks");
    const on = !!(S.rec || S.typing);
    const want = on ? pointed() : [];
    const hov = on && S.hover && S.hover.isConnected ? S.hover : null;
    const boxes = [...want.map((p, i) => ({ p, el: p.el.node, n: i + 1 })), ...(hov && !S.area && !want.some((p) => !p.box && p.el.node === hov) ? [{ el: hov, n: 0 }] : [])];
    while (layer.children.length > boxes.length) layer.lastChild.remove();
    boxes.forEach((b, i) => {
      let d = layer.children[i];
      if (!d) { d = document.createElement("div"); d.className = "mark"; d.innerHTML = `<button class="num" title="Take this one back"></button>`; layer.append(d); }
      const a = b.p?.box;
      const r = a ? { left: a.x - scrollX, top: a.y - scrollY, width: a.w, height: a.h } : b.el.isConnected ? b.el.getBoundingClientRect() : null;
      d.hidden = !r || (!r.width && !r.height);
      if (d.hidden) return;
      d.classList.toggle("hover", !b.n);
      d.classList.toggle("area", !!a);
      d.firstChild.textContent = b.n ? String(b.n) : "";
      d.firstChild.dataset.unmark = b.n || "";
      d.style.transform = `translate(${r.left - 3}px, ${r.top - 3}px)`;
      d.style.width = `${r.width + 6}px`; d.style.height = `${r.height + 6}px`;
    });
  }

  // Where each request in the room was made, on this page.
  function drawPins() {
    const layer = root.querySelector("#pins");
    const want = S.items.filter((it) => it.anchor?.path === location.pathname && it.anchor.sel && it.status !== "empty");
    while (layer.children.length > want.length) layer.lastChild.remove();
    want.forEach((it, i) => {
      let el = found.get(it.anchor.sel);
      if (!el || !el.isConnected) { try { el = document.querySelector(it.anchor.sel); } catch { el = null; } found.set(it.anchor.sel, el); }
      let d = layer.children[i];
      if (!d) { d = document.createElement("button"); d.className = "pin"; d.onclick = () => { S.panel = true; S.focus = d.dataset.id; render(); }; layer.append(d); }
      const r = el?.getBoundingClientRect();
      d.hidden = !r || (!r.width && !r.height);
      if (d.hidden) return;
      d.dataset.id = it.id;
      d.dataset.state = it.confirmed ? "ok" : it.status;
      d.classList.toggle("flash", S.flash === it.id);
      d.textContent = String(S.items.indexOf(it) + 1);
      d.title = `${it.from}: ${it.said || it.title || "…"}${it.note ? `\n${it.by || "Agent"}: ${it.note}` : ""}`;
      // On the element's corner, so it never hides what it marks.
      d.style.transform = `translate(${Math.min(innerWidth - 22, r.right - 9)}px, ${Math.max(2, r.top - 9)}px)`;
    });
  }

  async function accept(id) {
    const res = await realFetch("/__pay/api/accept", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id }) });
    toast(res.ok ? (S.agents.length ? `In the queue. ${S.agents[0]} is waiting for it.` : "In the queue for your agents") : "Could not accept that.");
  }

  async function confirm(id) {
    const res = await realFetch("/__pay/api/confirm", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id }) });
    toast(res.ok ? "Thanks. Marked as right." : "Could not save that.");
  }

  // MARK: The bar

  function toast(s, ms = 3500) {
    S.toast = s; render();
    clearTimeout(toast.t);
    if (ms) toast.t = setTimeout(() => { S.toast = null; render(); }, ms);
  }

  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const ICON = {
    check: '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12l5 5L20 7"/></svg>',
    eye: '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>',
    area: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-dasharray="3 3"><rect x="4" y="4" width="16" height="16" rx="2"/></svg>',
    mic: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="9" y="2" width="6" height="12" rx="3"/><path d="M5 10a7 7 0 0 0 14 0M12 17v5"/></svg>',
    type: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 7V5h16v2M9 19h6M12 5v14"/></svg>',
    list: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/></svg>',
    lock: '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>',
    spark: '<svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor"><path d="M12 2l2.2 6.6L21 11l-6.8 2.4L12 20l-2.2-6.6L3 11l6.8-2.4z"/></svg>',
    min: '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M6 12h12"/></svg>',
  };

  function stateText(it) {
    if (it.confirmed) return ["ok", `Confirmed by ${it.mine ? "you" : it.from}`];
    return {
      processing: ["wait", "Writing it down…"], empty: ["muted", "Nothing heard"],
      triage: ["wait", `Waiting for ${S.owner || "the owner"} to accept`], open: ["queued", "Queued for the agent"],
      in_progress: ["busy", `${it.by || "The agent"} is on it`], done: ["done", "Done"],
    }[it.status] || ["muted", it.status];
  }

  /** The agent in the room: working on something, or waiting for the next request. */
  function agentNow() {
    const busy = S.items.find((it) => it.status === "in_progress");
    if (busy) return { short: `${busy.by || "Agent"} working`, title: `${busy.by || "An agent"} is working on “${busy.title || "a request"}…”` };
    if (S.agents.length) return { short: `${S.agents[0]} ready`, title: `${S.agents.join(", ")} ${S.agents.length > 1 ? "are" : "is"} waiting for requests and fixes them as they come` };
    return null;
  }

  /** The owner's view of the link: share it, change how it works, end it. */
  function sessionHTML() {
    const sw = (key, on, title, detail) => `<button class="setting" data-set="${key}" aria-pressed="${on}"><span><b>${title}</b><small>${detail}</small></span><i class="switch${on ? " on" : ""}"></i></button>`;
    return `<div class="session">
      <div class="srow"><span class="livebadge"><i></i>LIVE</span><code title="${esc(S.link)}">${esc(S.link.replace(/^https?:\/\//, ""))}</code><button id="copyLink">${S.copied ? "Copied" : "Copy link"}</button></div>
      ${sw("trusted", S.straight, "Send requests straight to agents", S.straight ? "Guests' requests go to the queue as they come." : "You accept each request first.")}
      ${sw("private", S.privateMode, "Guests see only their own requests", S.privateMode ? "Each guest sees what they asked for." : "Everyone in the link sees every request.")}
      ${S.ending ? `<div class="ending"><span>End the link for everyone? It stops opening right away.</span><button id="endNo" class="ghost">Keep it</button><button id="endYes" class="danger">End</button></div>`
        : `<button id="endLive" class="danger ghosty">End live review</button>`}
    </div>`;
  }

  async function setting(body) {
    try { await realFetch("/__pay/api/settings", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }); }
    catch { toast("Could not change it. Is the link still live?"); }
  }

  function itemsHTML() {
    if (!S.items.length) return `<p class="empty">Nothing asked yet. Press Talk, point at things on the page and say what should change.</p>`;
    return [...S.items].reverse().map((it) => {
      const [cls, text] = stateText(it), n = S.items.indexOf(it) + 1;
      const check = it.mine && it.status === "done" && !it.confirmed;
      const accept = S.role === "owner" && it.status === "triage";
      return `<li class="${S.focus === it.id ? "focus" : ""}">
        <div class="row"><span class="n">${n}</span><b>${esc(it.mine ? "You" : it.from)}</b>${it.private ? `<span class="priv" title="Only ${esc(S.owner)} and you see this">${ICON.lock}</span>` : ""}${it.part ? `<span class="part">${esc(it.part)}</span>` : ""}<span class="chip ${cls}">${esc(text)}</span></div>
        <div class="said">${it.said || it.title ? `“${esc(it.said || it.title)}”` : ""}</div>
        ${it.note && it.status === "done" ? `<div class="fix">${esc(it.note)}</div>` : ""}
        ${accept ? `<div class="check"><span>${esc(it.from)} asked for this.</span><button data-accept="${esc(it.id)}" class="dark">Accept</button></div>` : ""}
        ${check ? `<div class="check"><span>Is it right now?</span><button data-ok="${esc(it.id)}" class="dark">Looks right</button><button data-no="${esc(it.id)}">Not yet</button></div>` : ""}
      </li>`;
    }).join("");
  }

  // Redrawn only when it changed, so focus, a half-typed answer and hover stay put.
  const put = (el, html) => { if (el.__h === html) return false; el.__h = html; el.innerHTML = html; return true; };

  function render() {
    if (!root) return;
    const bar = root.querySelector("#bar"), panel = root.querySelector("#panel"), t = root.querySelector("#toast");
    // What is typed and how far the list is scrolled survive the redraw.
    const typed = root.querySelector("#text")?.value, nameTyped = root.querySelector("#name")?.value, scroll = panel.scrollTop;
    root.querySelector("#ui").classList.toggle("small", S.small && !S.rec);
    t.hidden = !S.toast; t.textContent = S.toast || "";
    root.querySelector("#mini").hidden = !S.small || !!S.rec;
    bar.hidden = S.small && !S.rec;
    const others = S.peers.filter((p) => p.id !== S.me);
    const faces = others.slice(0, 4).map((p) => `<span class="face${p.talking ? " talking" : ""}" style="background:${p.color}" title="${esc(p.name)}${p.talking ? " is talking" : ""}">${esc((p.name || "?")[0].toUpperCase())}</span>`).join("");
    if (S.ended) {
      put(bar, `<span class="dot"></span><span class="who">${S.role === "owner" ? "You ended the live review" : `${esc(S.owner || "They")} ended the live review`}</span>
        <span class="hint">${S.role === "owner" ? "The link no longer opens." : "Thanks for the feedback."}</span>`);
    } else if (S.rec) {
      const s = Math.floor(now());
      put(bar, `<span class="dot rec"></span><span class="time">${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}</span>
        <span class="hint">${S.area ? "Drag a box over the area. Esc to stop." : pointed().length ? `${pointed().length} pointed at. Click a number to take it back.` : S.rec.followUp ? "Say what is still not right." : "Point at things and talk. ⌥-drag for an area."}</span>
        <button id="areaBtn" class="ghost${S.area ? " on" : ""}" title="Drag a box over an area (or hold ⌥ and drag)">${ICON.area}Area</button>
        <button id="cancel" class="ghost" title="Cancel (Esc)">esc</button><button id="stop" class="dark">Done <kbd>⌥⌥</kbd></button>`);
    } else {
      const open = S.items.filter((it) => it.mine && it.status === "done" && !it.confirmed).length;
      put(bar, `<span class="dot${S.connected ? " on" : ""}" title="${S.connected ? "Live" : "Reconnecting…"}"></span>
        <span class="who">${S.role === "owner" ? "Your live review" : `${esc(S.owner || "Live review")}'s app`}</span>${faces ? `<span class="faces">${faces}</span>` : ""}
        ${agentNow() ? `<span class="agent" title="${esc(agentNow().title)}">${ICON.spark}<span>${esc(agentNow().short)}</span></span>` : ""}
        <button id="talk" class="dark">${ICON.mic}Talk <kbd>⌥⌥</kbd></button>
        <button id="type" class="icon" title="Type instead">${ICON.type}</button>
        ${S.privateMode || S.role === "owner" ? "" : `<button id="lock" class="icon${S.lock ? " active" : ""}" title="${S.lock ? `Private: only ${esc(S.owner)} sees your next recordings` : "Visible to everyone in the link. Press to make it private"}">${ICON.lock}</button>`}
        <button id="list" class="icon${S.panel ? " active" : ""}" title="The room's requests">${ICON.list}${S.items.length ? `<span class="count${open ? " hot" : ""}">${open || S.items.length}</span>` : ""}</button>
        <button id="small" class="icon" title="Make the bar small">${ICON.min}</button>`);
    }
    const checking = S.items.find((it) => it.id === S.check && it.status === "done" && !it.confirmed);
    if (!checking) S.check = null;
    panel.classList.toggle("compact", !!checking && !S.panel && !S.asking && !S.typing);
    panel.hidden = (!S.panel && !checking) || S.small;
    let html = "";
    if (!panel.hidden && panel.classList.contains("compact")) {
      html = `<div class="row"><span class="n">${S.items.indexOf(checking) + 1}</span><b>Done</b>${checking.by ? `<span class="part">by ${esc(checking.by)}</span>` : ""}</div>
        ${checking.note ? `<div class="fix">${esc(checking.note)}</div>` : ""}
        <div class="asked">You asked: “${esc(checking.said || checking.title || "")}”</div>
        <div class="check"><span>Have a look. Is it right?</span><button data-ok="${esc(checking.id)}" class="dark">Looks right</button><button data-no="${esc(checking.id)}">Not yet</button></div>`;
    } else if (!panel.hidden) {
      if (S.asking?.welcome) {
        html = `<h3>${esc(S.owner || "Someone")} is sharing their app with you</h3>
          <p>It's the real app, running on their computer: use it as you normally would. When something should change, press <b>Talk</b>, point at it and say what. ${S.trusted ? "Their agent picks it up" : `${esc(S.owner || "They")} sees it with your name`}, and you can watch it get fixed right here.</p>
          <form id="nameForm"><input id="name" autocomplete="name" placeholder="Your name" value="${esc(S.name)}"><button type="button" id="later" class="ghost">Not now</button><button class="dark">Join</button></form>`;
      } else if (S.asking) {
        html = `<h3>Your name</h3><p>So ${esc(S.owner || "they")} know${S.owner ? "s" : ""} who asked.</p>
          <form id="nameForm"><input id="name" autocomplete="name" placeholder="Your name" value="${esc(S.name)}"><button class="dark">Start</button></form>`;
      } else if (S.typing) {
        html = `<h3>Type it instead</h3><p>Click things on the page to point at them, or <button id="areaBtn" class="link">drag a box</button> over an area (${pointed().length} so far), then say what should change.</p>
          <textarea id="text" rows="4" placeholder="This button should…"></textarea>
          <div class="actions"><button id="typeCancel" class="ghost">Cancel</button><button id="typeSend" class="dark">Send</button></div>`;
      } else {
        const people = S.peers.map((p) => `<span class="person"><span class="face${p.talking ? " talking" : ""}" style="background:${p.color}">${esc((p.name || "?")[0].toUpperCase())}</span>${esc(p.id === S.me ? "You" : p.name)}${p.role === "owner" ? " (owner)" : ""}${p.talking ? " · talking" : ""}</span>`).join("");
        const ag = agentNow();
        html = `<div class="head"><h3>Requests</h3><button id="close" class="icon" title="Close">${ICON.min}</button></div>
          <div class="people">${people}${ag ? `<span class="person agentp">${ICON.spark}${esc(ag.title)}</span>` : S.role === "owner" ? `<span class="person muted">No agent is waiting. Ask yours to “work through Point and Yap live”.</span>` : ""}</div>
          <ul>${itemsHTML()}</ul>
          ${S.role === "owner" ? sessionHTML() : `<div class="rules">
            <span>${S.trusted ? `${ICON.spark}Requests go straight to the agent` : `${ICON.check}${esc(S.owner)} accepts each request first`}</span>
            <span>${S.privateMode ? `${ICON.lock}Only ${esc(S.owner)} sees what you send` : `${ICON.eye}Everyone here sees the requests`}</span></div>`}`;
        if (S.focus) setTimeout(() => { root.querySelector("li.focus")?.scrollIntoView({ block: "nearest" }); S.focus = null; }, 0);
      }
    }
    if (!panel.hidden && put(panel, html)) {
      if (typed != null && root.querySelector("#text")) root.querySelector("#text").value = typed;
      if (nameTyped != null && root.querySelector("#name")) root.querySelector("#name").value = nameTyped;
      const n = root.querySelector("#name"); if (n) setTimeout(() => n.focus(), 0);
      panel.scrollTop = scroll;
    }
  }

  function wire() {
    root.addEventListener("click", (e) => {
      const b = e.target.closest("button");
      if (!b) return;
      if (b.id === "talk") start();
      else if (b.id === "stop") stop();
      else if (b.id === "cancel") cancel();
      else if (b.id === "areaBtn") areaMode(!S.area);
      else if (b.id === "copyLink") { navigator.clipboard?.writeText(S.link).then(() => { S.copied = true; render(); setTimeout(() => { S.copied = false; render(); }, 1600); }, () => toast(S.link, 6000)); }
      else if (b.dataset.set === "trusted") { S.straight = !S.straight; render(); setting({ trusted: S.straight }); }
      else if (b.dataset.set === "private") { S.privateMode = !S.privateMode; render(); setting({ private: S.privateMode }); }
      else if (b.id === "endLive") { S.ending = true; render(); }
      else if (b.id === "endNo") { S.ending = false; render(); }
      else if (b.id === "endYes") { S.ending = false; setting({ end: true }); }
      else if (b.dataset.unmark) unmark(+b.dataset.unmark);
      else if (b.id === "type") { S.typing = { t0: performance.now(), points: [] }; S.panel = true; render(); setTimeout(() => root.querySelector("#text")?.focus(), 0); }
      else if (b.id === "later") { S.asking = null; S.panel = false; render(); }
      else if (b.id === "typeCancel") { S.typing = null; render(); }
      else if (b.id === "typeSend") sendTyped();
      else if (b.id === "lock") { S.lock = !S.lock; toast(S.lock ? `Private: only ${S.owner} will see it` : "Visible to everyone in the link"); }
      else if (b.id === "list" || b.id === "close") { S.panel = !S.panel; render(); }
      else if (b.id === "small") { S.small = true; S.panel = false; store.set("pay-small", "1"); render(); }
      else if (b.id === "mini") { S.small = false; store.set("pay-small", "0"); render(); }
      else if (b.dataset.ok) { const id = b.dataset.ok; S.check = S.items.find((it) => it.id !== id && it.mine && it.status === "done" && !it.confirmed)?.id || null; confirm(id); render(); }
      else if (b.dataset.accept) accept(b.dataset.accept);
      else if (b.dataset.no) { S.check = null; start(b.dataset.no); }
    });
    root.addEventListener("submit", (e) => {
      e.preventDefault();
      const n = root.querySelector("#name").value.trim();
      if (!n) return;
      S.name = n.slice(0, 40); store.set("pay-name", S.name);
      send({ t: "hello", name: S.name });
      const welcome = S.asking?.welcome, then = S.asking?.then; S.asking = null; S.panel = false; render();
      if (welcome && !then) toast(`Hi ${S.name}. Press Talk (or ⌥ twice) when something should change.`, 5000);
      then?.();
    });
    // Keys typed into the bar stay in the bar.
    for (const k of ["keydown", "keyup", "keypress"]) root.addEventListener(k, (e) => { if (e.key !== "Escape") e.stopPropagation(); });
  }

  const CSS_TEXT = `
    :host { all: initial; }
    * { box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
    [hidden] { display: none !important; }
    .layer { position: fixed; inset: 0; pointer-events: none; z-index: 2147483646; }
    .cursor { position: absolute; left: 0; top: 0; transition: transform 90ms linear; }
    .cursor span { position: absolute; left: 14px; top: 16px; color: #fff; font-size: 11px; font-weight: 600; padding: 2px 6px; border-radius: 6px; white-space: nowrap; }
    .cursor.talking span::after { content: " · talking"; font-weight: 400; }
    .mark { position: absolute; left: 0; top: 0; border: 2px solid #e5484d; border-radius: 6px; background: rgba(229,72,77,.06); }
    .mark.hover { border-style: dashed; border-color: rgba(229,72,77,.6); background: none; }
    .mark.area { border-style: solid; border-radius: 2px; background: rgba(229,72,77,.1); }
    .mark .num { position: absolute; left: -9px; top: -9px; min-width: 18px; height: 18px; border-radius: 9px; background: #e5484d; color: #fff;
      font-size: 10px; font-weight: 700; display: grid; place-items: center; padding: 0 4px; border: 2px solid #fff; line-height: 1; gap: 0;
      pointer-events: auto; cursor: pointer; box-shadow: none; }
    .mark .num:hover { font-size: 0; min-width: 18px; padding: 0; background: #1a1a1a; }
    .mark .num:hover::after { content: "×"; font-size: 13px; }
    .mark.hover .num { display: none; }
    #area { position: fixed; inset: 0; z-index: 2147483646; cursor: crosshair; touch-action: none; }
    #area .sel { position: absolute; left: 0; top: 0; border: 2px solid #e5484d; background: rgba(229,72,77,.1); border-radius: 2px; }
    button.ghost.on { background: #e5484d22; color: #e5484d; }
    .rules { display: flex; flex-wrap: wrap; gap: 6px 14px; margin-top: 12px; font-size: 12px; color: #8a8d94; }
    .rules span { display: inline-flex; align-items: center; gap: 5px; } .rules svg { width: 12px; height: 12px; }
    .session { margin-top: 12px; padding-top: 12px; border-top: 1px solid #ececef; display: grid; grid-template-columns: minmax(0, 1fr); gap: 10px; }
    .srow { display: flex; align-items: center; gap: 8px; background: #f6f6f7; border-radius: 9px; padding: 4px 4px 4px 8px; }
    .srow code { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; color: #5c5f66; }
    .srow button { flex: none; height: 26px; font-size: 12px; }
    .livebadge { display: inline-flex; align-items: center; gap: 5px; font-size: 10px; font-weight: 700; letter-spacing: .06em; color: #e5484d; background: #e5484d1a; border-radius: 10px; padding: 3px 7px; }
    .livebadge i { width: 6px; height: 6px; border-radius: 3px; background: #e5484d; animation: breathe 1.8s ease-in-out infinite; }
    @keyframes breathe { 50% { opacity: .35; } }
    button.setting { all: unset; display: flex; align-items: center; gap: 10px; cursor: pointer; padding: 2px 0; }
    button.setting > span { flex: 1; display: grid; gap: 1px; } button.setting b { font-size: 12.5px; font-weight: 500; } button.setting small { font-size: 11.5px; color: #8a8d94; }
    .switch { display: block; flex: none; width: 28px; height: 16px; border-radius: 8px; background: #d4d5d9; position: relative; transition: background .15s; }
    .switch::after { content: ""; position: absolute; left: 2px; top: 2px; width: 12px; height: 12px; border-radius: 6px; background: #fff; box-shadow: 0 1px 2px rgba(0,0,0,.25); transition: transform .15s; }
    .switch.on { background: #30a46c; } .switch.on::after { transform: translateX(12px); }
    button.danger { color: #fff; background: #e5484d; border-color: #e5484d; } button.danger:hover { background: #d13d42; }
    button.danger.ghosty { justify-self: start; color: #e5484d; background: transparent; border-color: transparent; padding: 0 2px; height: 24px; }
    button.danger.ghosty:hover { text-decoration: underline; background: transparent; }
    .ending { display: flex; align-items: center; gap: 6px; font-size: 12px; } .ending span { flex: 1; color: #5c5f66; }
    button.link { all: unset; color: inherit; text-decoration: underline; cursor: pointer; }
    .pin { position: absolute; left: 0; top: 0; width: 18px; height: 18px; border-radius: 9px; border: 2px solid #fff; padding: 0;
      font-size: 10px; font-weight: 700; color: #fff; background: #b8860b; pointer-events: auto; justify-content: center; line-height: 1; gap: 0; cursor: pointer; box-shadow: 0 1px 4px rgba(0,0,0,.3); }
    .pin[data-state="in_progress"] { background: #5c5f66; } .pin[data-state="done"] { background: #2f7a4b; } .pin[data-state="ok"] { background: #2f7a4b; outline: 2px solid #9ad3ae; }
    .pin[data-state="triage"], .pin[data-state="processing"] { background: #1f4e8c; }
    #ui { position: fixed; left: 50%; bottom: max(14px, env(safe-area-inset-bottom)); transform: translateX(-50%); z-index: 2147483647;
      display: flex; flex-direction: column; align-items: center; gap: 8px; width: max-content; max-width: calc(100vw - 20px); }
    #bar { display: flex; align-items: center; gap: 8px; padding: 6px 6px 6px 14px; background: #fff; color: #1d1f23; border: 1px solid #e3e4e7;
      border-radius: 14px; box-shadow: 0 6px 24px rgba(0,0,0,.14); font-size: 13px; max-width: 100%; flex-wrap: wrap; justify-content: center; }
    .dot { width: 8px; height: 8px; border-radius: 4px; background: #c9cbd0; flex: none; } .dot.on { background: #30a46c; }
    .dot.rec { background: #e5484d; animation: pulse 1.2s ease-in-out infinite; }
    @keyframes pulse { 50% { opacity: .35; } }
    .who { font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 16em; }
    .time { font-variant-numeric: tabular-nums; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    .hint { color: #5c5f66; }
    button { font: inherit; font-size: 13px; border: 1px solid #e3e4e7; background: #fff; color: #1d1f23; border-radius: 9px; height: 30px; padding: 0 11px;
      display: inline-flex; align-items: center; gap: 6px; cursor: pointer; white-space: nowrap; }
    button:hover { background: #f3f3f5; }
    button.dark { background: #1d1f23; color: #fff; border-color: #1d1f23; } button.dark:hover { background: #33363c; }
    button.ghost { border-color: transparent; color: #8a8d94; }
    button.icon { width: 30px; padding: 0; justify-content: center; position: relative; color: #5c5f66; }
    button.icon.active { background: #f3f3f5; color: #1d1f23; }
    kbd { font: 11px ui-monospace, Menlo, monospace; color: #9a9da4; }
    .count { position: absolute; top: -5px; right: -5px; min-width: 16px; height: 16px; border-radius: 8px; background: #5c5f66; color: #fff; font-size: 10px;
      font-weight: 700; display: grid; place-items: center; padding: 0 4px; } .count.hot { background: #e5484d; }
    .faces { display: inline-flex; } .faces .face { margin-left: -4px; border: 2px solid #fff; }
    .face { width: 22px; height: 22px; border-radius: 11px; color: #fff; font-size: 11px; font-weight: 700; display: inline-grid; place-items: center; flex: none; }
    .face.talking { box-shadow: 0 0 0 2px #fff, 0 0 0 4px #e5484d; }
    #mini { width: 40px; height: 40px; border-radius: 20px; padding: 0; justify-content: center; box-shadow: 0 6px 24px rgba(0,0,0,.18); background: #1d1f23; border-color: #1d1f23; }
    #mini::after { content: ""; width: 10px; height: 10px; border-radius: 5px; background: #e5484d; }
    #ui.small { left: auto; right: 14px; transform: none; }
    #panel { width: min(380px, calc(100vw - 20px)); max-height: min(60vh, 520px); overflow: auto; background: #fff; color: #1d1f23; border: 1px solid #e3e4e7;
      border-radius: 14px; box-shadow: 0 10px 32px rgba(0,0,0,.16); padding: 14px; font-size: 13px; line-height: 1.45; }
    #panel.compact { padding: 10px 12px; } #panel.compact .check { margin: 6px 0 0; }
    .asked { margin: 4px 0 0 24px; font-size: 12px; color: #8a8d94; }
    .said, .fix, .asked { overflow-wrap: anywhere; white-space: pre-wrap; }
    .pin.flash { animation: flash .6s ease-in-out 6; } @keyframes flash { 50% { transform-origin: center; box-shadow: 0 0 0 8px rgba(48,164,108,.45); } }
    #panel h3 { margin: 0 0 4px; font-size: 14px; font-weight: 600; } #panel p { margin: 0 0 10px; color: #5c5f66; }
    .head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; }
    .people { display: flex; flex-wrap: wrap; gap: 6px 12px; margin-bottom: 10px; color: #5c5f66; font-size: 12px; }
    .person { display: inline-flex; align-items: center; gap: 6px; }
    ul { list-style: none; margin: 0; padding: 0; } li { padding: 10px 0; border-top: 1px solid #efeff1; } li.focus { background: #fffbea; }
    .row { display: flex; align-items: center; gap: 6px; } .row b { font-weight: 600; }
    .n { width: 18px; height: 18px; border-radius: 9px; background: #efeff1; font-size: 10px; font-weight: 700; display: inline-grid; place-items: center; }
    .priv { color: #8a8d94; display: inline-flex; }
    .part { font-size: 11px; color: #8a8d94; }
    .agent { display: inline-flex; align-items: center; gap: 4px; font-size: 12px; color: #6e56cf; background: #f4f0fe; border: 1px solid #e1d9fb;
      border-radius: 999px; padding: 2px 8px; white-space: nowrap; }
    .agentp { color: #6e56cf; } .person.muted { color: #8a8d94; }
    .chip { margin-left: auto; font-size: 11px; padding: 2px 8px; border-radius: 999px; border: 1px solid; white-space: nowrap; }
    .chip.wait { color: #1f4e8c; background: #eef4fd; border-color: #c9dbf5; } .chip.queued { color: #6b5414; background: #fff7e0; border-color: #f3e3b5; }
    .chip.busy { color: #3a3c41; background: #f3f3f5; border-color: #e3e4e7; } .chip.done, .chip.ok { color: #2f7a4b; background: #f1faf4; border-color: #cfe8d8; }
    .chip.muted { color: #8a8d94; background: #fafafa; border-color: #efeff1; }
    .said { margin: 4px 0 0 24px; } .fix { margin: 4px 0 0 24px; color: #2f7a4b; }
    .check { display: flex; align-items: center; gap: 6px; margin: 8px 0 0 24px; flex-wrap: wrap; } .check span { color: #5c5f66; margin-right: auto; }
    .empty { color: #8a8d94; } .foot { margin: 10px 0 0 !important; font-size: 12px; color: #8a8d94 !important; }
    form, .actions { display: flex; gap: 8px; } .actions { justify-content: flex-end; margin-top: 8px; }
    input, textarea { font: inherit; font-size: 14px; border: 1px solid #d5d7db; border-radius: 9px; padding: 6px 10px; flex: 1; width: 100%; color: #1d1f23; background: #fff; }
    textarea { resize: vertical; }
    #toast { background: #1d1f23; color: #fff; padding: 7px 13px; border-radius: 999px; font-size: 13px; max-width: 100%; text-align: center; }
    @media (prefers-color-scheme: dark) {
      #bar, #panel, button { background: #1f2024; color: #ececee; border-color: #34363b; } button:hover, button.icon.active { background: #2b2d32; }
      button.dark { background: #ececee; color: #1d1f23; border-color: #ececee; } .hint, #panel p, .people { color: #a2a5ab; }
      li { border-color: #2b2d32; } .n { background: #2b2d32; } input, textarea { background: #16171a; color: #ececee; border-color: #3a3c41; }
      .faces .face { border-color: #1f2024; } li.focus { background: #2a2617; }
      .agent { color: #b8a6f5; background: #262040; border-color: #3a3060; } .agentp { color: #b8a6f5; }
      .chip.wait { color: #9dbcf0; background: #1a2638; border-color: #2a3c58; } .chip.queued { color: #e6c87a; background: #2e2715; border-color: #4a3e1e; }
      .chip.busy { color: #c9cbd0; background: #2b2d32; border-color: #3a3c41; } .chip.done, .chip.ok { color: #7fd1a0; background: #16291e; border-color: #24452f; }
      .chip.muted { color: #8a8d94; background: #1f2024; border-color: #2b2d32; }
      .session { border-color: #2b2d32; } .srow { background: #16171a; } .srow code, .ending span { color: #a2a5ab; } .switch { background: #3a3c41; }
    }
    @media (max-width: 520px) { .who, kbd, .hint, .agent span { display: none; } }
  `;

  function mount() {
    host = document.createElement("pointandyap-bar");
    root = host.attachShadow({ mode: "open" });
    root.innerHTML = `<style>${CSS_TEXT}</style><div class="layer" id="marks"></div><div class="layer" id="pins"></div><div class="layer" id="cursors"></div>
      <div id="area" hidden><div class="sel" hidden></div></div>
      <div id="ui"><div id="toast" hidden></div><div id="panel" hidden></div><div id="bar"></div><button id="mini" title="Point and Yap" hidden></button></div>`;
    const parent = () => document.body || document.documentElement;
    parent().append(host);
    // Some apps replace the whole body (a router, a framework's error page): come back when that happens.
    setInterval(() => { if (!host.isConnected) parent().append(host); }, 1500);
    wire();
    wireArea();
    render();
    connect();
    requestAnimationFrame(drawCursors);
  }

  // After the page has loaded, so a framework that hydrates the document (Next.js, Remix) never finds a node it did
  // not render. The page's errors are caught from the start all the same.
  if (document.readyState === "complete") mount(); else addEventListener("load", () => setTimeout(mount, 250));
  // For tests: what a recording would carry for a point.
  window.__pointandyap = { describe, resolve, serialize };
})();
