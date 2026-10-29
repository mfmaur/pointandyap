// The review-link relay. It keeps ciphertext it cannot read: a link's screenshots (sealed with the key in the link's
// #fragment, which browsers never send) and what guests send back (sealed to the owner's Mac). The owner's Mac creates
// a link, uploads the screenshots, and later fetches and deletes what guests sent, with the link's bearer token.
//
//   POST   /api/links                      -> {id, token}
//   PUT    /api/links/:id/tour             (owner) the sealed screenshots
//   GET    /api/links/:id/tour             the sealed screenshots, for the page
//   POST   /api/links/:id/feedback         a guest's sealed feedback
//   GET    /api/links/:id/feedback         (owner) {items: [{id, size}]}
//   GET    /api/links/:id/feedback/:fid    (owner) one, sealed
//   DELETE /api/links/:id/feedback/:fid    (owner)
//   DELETE /api/links/:id                  (owner) the link and everything in it
//   GET    /r/:id                          the review page

const TTL = 30 * 86400e3;
const MAX_TOUR = 25 << 20, MAX_FEEDBACK = 20 << 20, MAX_WAITING = 200;
const ID = /^[A-Za-z0-9_-]{16}$/, FID = /^[0-9a-z]{6,40}$/;

const PAGE_HEADERS = {
  "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; img-src blob:; connect-src 'self'; " +
    "media-src blob:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  "Referrer-Policy": "no-referrer",
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
};

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const p = url.pathname.split("/").filter(Boolean);
    try {
      if (p[0] === "r" && p.length === 2 && ID.test(p[1]) && req.method === "GET") {
        const page = await env.ASSETS.fetch(new Request(new URL("/review.html", url)));
        return new Response(page.body, { headers: { "Content-Type": "text/html; charset=utf-8", ...PAGE_HEADERS } });
      }
      if (p[0] !== "api" || p[1] !== "links") return env.ASSETS.fetch(req);
      if (p.length === 2 && req.method === "POST") return create(env);

      const id = p[2];
      if (!ID.test(id)) return text("no such link", 404);
      const meta = await env.BLOBS.get(`links/${id}/meta.json`).then((o) => o && o.json());
      if (!meta || meta.expires < Date.now()) return text("no such link", 404);
      const owner = (await sha256(bearer(req))) === meta.tokenHash;
      const base = `links/${id}`;

      if (p.length === 3 && req.method === "DELETE") {
        if (!owner) return text("not yours", 403);
        for (let cursor; ;) {
          const page = await env.BLOBS.list({ prefix: `${base}/`, cursor });
          if (page.objects.length) await env.BLOBS.delete(page.objects.map((o) => o.key));
          if (!page.truncated) break;
          cursor = page.cursor;
        }
        return text("deleted");
      }
      if (p[3] === "tour" && p.length === 4) {
        if (req.method === "GET") {
          const o = await env.BLOBS.get(`${base}/tour`);
          return o ? new Response(o.body, { headers: { "Content-Type": "application/octet-stream", "Cache-Control": "no-store" } }) : text("not yet", 404);
        }
        if (req.method === "PUT") {
          if (!owner) return text("not yours", 403);
          const body = await read(req, MAX_TOUR);
          if (!body) return text("too large", 413);
          await env.BLOBS.put(`${base}/tour`, body);
          return text("ok");
        }
      }
      if (p[3] === "feedback") {
        if (p.length === 4 && req.method === "POST") {
          const waiting = await env.BLOBS.list({ prefix: `${base}/fb/`, limit: MAX_WAITING });
          if (waiting.objects.length >= MAX_WAITING) return text("this link is full until its owner reads it", 429);
          const body = await read(req, MAX_FEEDBACK);
          if (!body || body.byteLength < 65 + 12 + 16) return text("not feedback", 413);
          const fid = Date.now().toString(36) + rand(6).toLowerCase().replace(/[^0-9a-z]/g, "0");
          await env.BLOBS.put(`${base}/fb/${fid}`, body);
          return json({ ok: true });
        }
        if (!owner) return text("not yours", 403);
        if (p.length === 4 && req.method === "GET") {
          const page = await env.BLOBS.list({ prefix: `${base}/fb/`, limit: MAX_WAITING });
          return json({ items: page.objects.map((o) => ({ id: o.key.split("/").pop(), size: o.size })) });
        }
        const fid = p[4];
        if (p.length === 5 && FID.test(fid)) {
          if (req.method === "GET") {
            const o = await env.BLOBS.get(`${base}/fb/${fid}`);
            return o ? new Response(o.body, { headers: { "Content-Type": "application/octet-stream" } }) : text("gone", 404);
          }
          if (req.method === "DELETE") { await env.BLOBS.delete(`${base}/fb/${fid}`); return text("deleted"); }
        }
      }
      return text("not found", 404);
    } catch (e) {
      return text("relay error", 500);
    }
  },
};

async function create(env) {
  const id = rand(12), token = rand(32);
  await env.BLOBS.put(`links/${id}/meta.json`, JSON.stringify({ tokenHash: await sha256(token), created: Date.now(), expires: Date.now() + TTL }));
  return json({ id, token, expires: new Date(Date.now() + TTL).toISOString() });
}

/** The body, or null when it is larger than max. */
async function read(req, max) {
  if (Number(req.headers.get("Content-Length") || 0) > max) return null;
  const body = await req.arrayBuffer();
  return body.byteLength > max ? null : body;
}

const bearer = (req) => (req.headers.get("Authorization") || "").replace(/^Bearer /, "");
const rand = (n) => btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(n)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const sha256 = async (s) => [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)))].map((b) => b.toString(16).padStart(2, "0")).join("");
const text = (s, status = 200) => new Response(s, { status, headers: { "Content-Type": "text/plain" } });
const json = (o, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
