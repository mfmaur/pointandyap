// pointandyap.com: the static page, plus /api/stats with the real GitHub numbers (stars, release downloads), cached 10 min.
const REPO = "mfmaur/pointandyap";

async function stats() {
  const h = { "User-Agent": "pointandyap.com", Accept: "application/vnd.github+json" };
  const out = { stars: 0, downloads: 0, version: null, download: null };
  const [repo, releases] = await Promise.all([
    fetch(`https://api.github.com/repos/${REPO}`, { headers: h }),
    fetch(`https://api.github.com/repos/${REPO}/releases?per_page=100`, { headers: h }),
  ]);
  if (repo.ok) out.stars = (await repo.json()).stargazers_count ?? 0;
  if (releases.ok) {
    const list = (await releases.json()).filter((r) => !r.draft && !r.prerelease);
    for (const r of list) for (const a of r.assets ?? []) if (a.name.endsWith(".dmg")) out.downloads += a.download_count;
    const dmg = list[0]?.assets?.find((a) => a.name.endsWith(".dmg"));
    if (dmg) { out.version = list[0].tag_name.replace(/^v/, ""); out.download = dmg.browser_download_url; }
  }
  return out;
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.hostname === "www.pointandyap.com") return Response.redirect(`https://pointandyap.com${url.pathname}`, 301);
    if (url.pathname === "/api/stats") {
      const cache = caches.default, key = new Request("https://pointandyap.com/api/stats");
      let res = await cache.match(key);
      if (!res) {
        let body;
        try { body = await stats(); } catch { body = { stars: 0, downloads: 0, version: null, download: null }; }
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
    // Not in search results until launch (remove the noindex header then).
    const headers = { ...Object.fromEntries(res.headers), "x-robots-tag": "noindex" };
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
