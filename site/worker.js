// pointandyap.com: the static page, plus /api/stats with the real GitHub numbers (stars, release downloads), cached 10 min.
// Every page view, download, installer run and app update check is counted in Analytics Engine (dataset
// pointandyap_events): no cookies, no script, no IP address kept; a visitor is a hash that changes every day.
const REPO = "mfmaur/pointandyap";
const LATEST_DMG = `https://github.com/${REPO}/releases/latest/download/PointAndYap.dmg`;
const BOT = /bot|crawl|spider|slurp|preview|facebookexternalhit|embedly|monitor|headless|python|go-http|wget|curl|httpclient|okhttp|axios|node-fetch/i;

async function track(env, request, event, url) {
  if (!env.EVENTS) return;
  const ua = request.headers.get("user-agent") ?? "";
  const day = new Date().toISOString().slice(0, 10);
  const ip = request.headers.get("cf-connecting-ip") ?? "";
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${env.VISITOR_SALT ?? ""}|${day}|${ip}|${ua}`));
  const visitor = [...new Uint8Array(digest).slice(0, 8)].map((b) => b.toString(16).padStart(2, "0")).join("");
  let refHost = "";
  try { refHost = new URL(request.headers.get("referer") ?? "").hostname.replace(/^www\./, ""); } catch {}
  if (refHost === "pointandyap.com") refHost = "";
  const source = url.searchParams.get("ref") ?? url.searchParams.get("utm_source") ?? "";
  const client = /Sparkle/.test(ua) ? "app" : /^curl\//.test(ua) ? "curl" : BOT.test(ua) ? "bot"
    : /iPhone|iPad|Android/.test(ua) ? "mobile" : /Macintosh/.test(ua) ? "mac" : "other";
  const version = /Point(?:%20| )?and(?:%20| )?Yap\/([\d.]+)/i.exec(ua)?.[1] ?? "";
  env.EVENTS.writeDataPoint({
    indexes: [event],
    blobs: [event, url.pathname, refHost, source.slice(0, 40), request.cf?.country ?? "", client, visitor, version],
    doubles: [1],
  });
}

async function stats() {
  const h = { "User-Agent": "pointandyap.com", Accept: "application/vnd.github+json" };
  const out = { stars: 0, downloads: 0, version: null, download: null };
  const [repo, releases] = await Promise.all([
    fetch(`https://api.github.com/repos/${REPO}`, { headers: h }),
    fetch(`https://api.github.com/repos/${REPO}/releases?per_page=100`, { headers: h }),
  ]);
  // GitHub allows 60 requests an hour per address without a login, shared with every site on the same Cloudflare
  // address: a refusal throws, so the last good numbers are shown instead of zeros.
  if (!repo.ok || !releases.ok) throw new Error(`github ${repo.status}/${releases.status}`);
  out.stars = (await repo.json()).stargazers_count ?? 0;
  {
    const list = (await releases.json()).filter((r) => !r.draft && !r.prerelease);
    for (const r of list) for (const a of r.assets ?? []) if (a.name.endsWith(".dmg")) out.downloads += a.download_count;
    const dmg = list[0]?.assets?.find((a) => a.name.endsWith(".dmg"));
    if (dmg) { out.version = list[0].tag_name.replace(/^v/, ""); out.download = dmg.browser_download_url; }
  }
  return out;
}

// The same numbers from shields.io (it reads GitHub with its own login and caches), for when GitHub refuses us.
async function shields() {
  const get = (path) => fetch(`https://img.shields.io/${path}.json`, { headers: { "User-Agent": "pointandyap.com" } })
    .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`shields ${r.status}`))));
  const num = (v) => {
    const m = /^([\d.]+)([kM]?)$/.exec(String(v ?? "").trim());
    return m ? Math.round(+m[1] * (m[2] === "k" ? 1e3 : m[2] === "M" ? 1e6 : 1)) : 0;
  };
  const [st, dl, rel] = await Promise.all([
    get(`github/stars/${REPO}`), get(`github/downloads/${REPO}/total`), get(`github/v/release/${REPO}`),
  ]);
  const version = /^v?(\d[\w.-]*)$/.exec(rel.value ?? "")?.[1] ?? null;
  return { stars: num(st.value), downloads: num(dl.value), version,
    download: version ? `https://github.com/${REPO}/releases/latest/download/PointAndYap.dmg` : null };
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.hostname === "www.pointandyap.com") return Response.redirect(`https://pointandyap.com${url.pathname}${url.search}`, 301);
    // The Download buttons (site and README) come through here, so a download is counted with where it came from.
    if (url.pathname === "/download") {
      ctx.waitUntil(track(env, request, "download", url));
      return Response.redirect(LATEST_DMG, 302);
    }
    if (request.method === "GET") {
      const event = url.pathname === "/" ? "view" : url.pathname === "/install.sh" ? "install" : url.pathname === "/appcast.xml" ? "update_check" : null;
      if (event) ctx.waitUntil(track(env, request, event, url));
    }
    if (url.pathname === "/api/stats") {
      const cache = caches.default, key = new Request("https://pointandyap.com/api/stats?v=launch4");
      let res = await cache.match(key);
      if (!res) {
        const lastKey = new Request("https://pointandyap.com/api/stats-last-good");
        let body;
        try {
          body = await stats().catch(() => shields());
          ctx.waitUntil(cache.put(lastKey, new Response(JSON.stringify(body), { headers: { "cache-control": "public, max-age=2592000" } })));
        } catch {
          const last = await cache.match(lastKey);
          body = last ? await last.json() : { stars: 0, downloads: 0, version: null, download: null };
        }
        res = new Response(JSON.stringify(body), {
          headers: { "content-type": "application/json", "cache-control": "public, max-age=600" },
        });
        ctx.waitUntil(cache.put(key, res.clone()));
      }
      return res;
    }
    // Media is asked for whole and sliced below (the assets binding does not answer ranges reliably).
    const media = url.pathname.startsWith("/media/");
    const res = await env.ASSETS.fetch(media ? new Request(url, { headers: { accept: request.headers.get("accept") ?? "*/*" } }) : request);
    const headers = Object.fromEntries(res.headers);
    // Safari plays a video only when it answers byte ranges; the assets binding sends the whole file, so slice it here.
    const range = /^bytes=(\d+)-(\d*)$/.exec(request.headers.get("range") ?? "");
    if (media && res.status === 200) {
      headers["accept-ranges"] = "bytes";
      if (range) {
        const buf = await res.arrayBuffer(), size = buf.byteLength;
        const start = +range[1], end = Math.min(range[2] ? +range[2] : size - 1, size - 1);
        if (start > end) return new Response(null, { status: 416, headers: { "content-range": `bytes */${size}` } });
        return new Response(buf.slice(start, end + 1), {
          status: 206,
          headers: { ...headers, "content-range": `bytes ${start}-${end}/${size}`, "content-length": String(end - start + 1) },
        });
      }
    }
    return new Response(res.body, { status: res.status, headers });
  },
};
