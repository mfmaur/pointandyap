var __defProp = Object.defineProperty;
var __name = (target, value) => __defProp(target, "name", { value, configurable: true });

// worker.js
var REPO = "mfmaur/pointandyap";
async function stats() {
  const h = { "User-Agent": "pointandyap.com", Accept: "application/vnd.github+json" };
  const out = { stars: 0, downloads: 0, version: null, download: null };
  const [repo, releases] = await Promise.all([
    fetch(`https://api.github.com/repos/${REPO}`, { headers: h }),
    fetch(`https://api.github.com/repos/${REPO}/releases?per_page=100`, { headers: h })
  ]);
  if (!repo.ok || !releases.ok) throw new Error(`github ${repo.status}/${releases.status}`);
  out.stars = (await repo.json()).stargazers_count ?? 0;
  {
    const list = (await releases.json()).filter((r) => !r.draft && !r.prerelease);
    for (const r of list) for (const a of r.assets ?? []) if (a.name.endsWith(".dmg")) out.downloads += a.download_count;
    const dmg = list[0]?.assets?.find((a) => a.name.endsWith(".dmg"));
    if (dmg) {
      out.version = list[0].tag_name.replace(/^v/, "");
      out.download = dmg.browser_download_url;
    }
  }
  return out;
}
__name(stats, "stats");
async function shields() {
  const get = /* @__PURE__ */ __name((path) => fetch(`https://img.shields.io/${path}.json`, { headers: { "User-Agent": "pointandyap.com" } }).then((r) => r.ok ? r.json() : Promise.reject(new Error(`shields ${r.status}`))), "get");
  const num = /* @__PURE__ */ __name((v) => {
    const m = /^([\d.]+)([kM]?)$/.exec(String(v ?? "").trim());
    return m ? Math.round(+m[1] * (m[2] === "k" ? 1e3 : m[2] === "M" ? 1e6 : 1)) : 0;
  }, "num");
  const [st, dl, rel] = await Promise.all([
    get(`github/stars/${REPO}`),
    get(`github/downloads/${REPO}/total`),
    get(`github/v/release/${REPO}`)
  ]);
  const version = /^v?(\d[\w.-]*)$/.exec(rel.value ?? "")?.[1] ?? null;
  return {
    stars: num(st.value),
    downloads: num(dl.value),
    version,
    download: version ? `https://github.com/${REPO}/releases/latest/download/PointAndYap.dmg` : null
  };
}
__name(shields, "shields");
var worker_default = {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.hostname === "www.pointandyap.com") return Response.redirect(`https://pointandyap.com${url.pathname}`, 301);
    if (url.pathname === "/api/stats") {
      const cache = caches.default, key = new Request("https://pointandyap.com/api/stats?v=launch4");
      let res2 = await cache.match(key);
      if (!res2) {
        const lastKey = new Request("https://pointandyap.com/api/stats-last-good");
        let body;
        try {
          body = await stats().catch(() => shields());
          ctx.waitUntil(cache.put(lastKey, new Response(JSON.stringify(body), { headers: { "cache-control": "public, max-age=2592000" } })));
        } catch {
          const last = await cache.match(lastKey);
          body = last ? await last.json() : { stars: 0, downloads: 0, version: null, download: null };
        }
        res2 = new Response(JSON.stringify(body), {
          headers: { "content-type": "application/json", "cache-control": "public, max-age=600" }
        });
        ctx.waitUntil(cache.put(key, res2.clone()));
      }
      return res2;
    }
    const media = url.pathname.startsWith("/media/");
    const res = await env.ASSETS.fetch(media ? new Request(url, { headers: { accept: request.headers.get("accept") ?? "*/*" } }) : request);
    const headers = Object.fromEntries(res.headers);
    const range = /^bytes=(\d+)-(\d*)$/.exec(request.headers.get("range") ?? "");
    if (media && res.status === 200) {
      headers["accept-ranges"] = "bytes";
      if (range) {
        const buf = await res.arrayBuffer(), size = buf.byteLength;
        const start = +range[1], end = Math.min(range[2] ? +range[2] : size - 1, size - 1);
        if (start > end) return new Response(null, { status: 416, headers: { "content-range": `bytes */${size}` } });
        return new Response(buf.slice(start, end + 1), {
          status: 206,
          headers: { ...headers, "content-range": `bytes ${start}-${end}/${size}`, "content-length": String(end - start + 1) }
        });
      }
    }
    return new Response(res.body, { status: res.status, headers });
  }
};

// ../../../../../../opt/homebrew/lib/node_modules/wrangler/templates/middleware/middleware-ensure-req-body-drained.ts
var drainBody = /* @__PURE__ */ __name(async (request, env, _ctx, middlewareCtx) => {
  try {
    return await middlewareCtx.next(request, env);
  } finally {
    try {
      if (request.body !== null && !request.bodyUsed) {
        const reader = request.body.getReader();
        while (!(await reader.read()).done) {
        }
      }
    } catch (e) {
      console.error("Failed to drain the unused request body.", e);
    }
  }
}, "drainBody");
var middleware_ensure_req_body_drained_default = drainBody;

// ../../../../../../opt/homebrew/lib/node_modules/wrangler/templates/middleware/middleware-miniflare3-json-error.ts
function reduceError(e) {
  return {
    name: e?.name,
    message: e?.message ?? String(e),
    stack: e?.stack,
    cause: e?.cause === void 0 ? void 0 : reduceError(e.cause)
  };
}
__name(reduceError, "reduceError");
var jsonError = /* @__PURE__ */ __name(async (request, env, _ctx, middlewareCtx) => {
  try {
    return await middlewareCtx.next(request, env);
  } catch (e) {
    const error = reduceError(e);
    const body = JSON.stringify(error);
    const headers = {
      "Content-Type": "application/json",
      "MF-Experimental-Error-Stack": "true"
    };
    const encoded = encodeURIComponent(body);
    if (encoded.length <= 8192) {
      headers["MF-Experimental-Error-Stack-Payload"] = encoded;
    }
    return new Response(body, { status: 500, headers });
  }
}, "jsonError");
var middleware_miniflare3_json_error_default = jsonError;

// .wrangler/tmp/bundle-F7O5kT/middleware-insertion-facade.js
var __INTERNAL_WRANGLER_MIDDLEWARE__ = [
  middleware_ensure_req_body_drained_default,
  middleware_miniflare3_json_error_default
];
var middleware_insertion_facade_default = worker_default;

// ../../../../../../opt/homebrew/lib/node_modules/wrangler/templates/middleware/common.ts
var __facade_middleware__ = [];
function __facade_register__(...args) {
  __facade_middleware__.push(...args.flat());
}
__name(__facade_register__, "__facade_register__");
function __facade_invokeChain__(request, env, ctx, dispatch, middlewareChain) {
  const [head, ...tail] = middlewareChain;
  const middlewareCtx = {
    dispatch,
    next(newRequest, newEnv) {
      return __facade_invokeChain__(newRequest, newEnv, ctx, dispatch, tail);
    }
  };
  return head(request, env, ctx, middlewareCtx);
}
__name(__facade_invokeChain__, "__facade_invokeChain__");
function __facade_invoke__(request, env, ctx, dispatch, finalMiddleware) {
  return __facade_invokeChain__(request, env, ctx, dispatch, [
    ...__facade_middleware__,
    finalMiddleware
  ]);
}
__name(__facade_invoke__, "__facade_invoke__");

// .wrangler/tmp/bundle-F7O5kT/middleware-loader.entry.ts
var __Facade_ScheduledController__ = class ___Facade_ScheduledController__ {
  constructor(scheduledTime, cron, noRetry) {
    this.scheduledTime = scheduledTime;
    this.cron = cron;
    this.#noRetry = noRetry;
  }
  scheduledTime;
  cron;
  static {
    __name(this, "__Facade_ScheduledController__");
  }
  #noRetry;
  noRetry() {
    if (!(this instanceof ___Facade_ScheduledController__)) {
      throw new TypeError("Illegal invocation");
    }
    this.#noRetry();
  }
};
function wrapExportedHandler(worker) {
  if (__INTERNAL_WRANGLER_MIDDLEWARE__ === void 0 || __INTERNAL_WRANGLER_MIDDLEWARE__.length === 0) {
    return worker;
  }
  for (const middleware of __INTERNAL_WRANGLER_MIDDLEWARE__) {
    __facade_register__(middleware);
  }
  const fetchDispatcher = /* @__PURE__ */ __name(function(request, env, ctx) {
    if (worker.fetch === void 0) {
      throw new Error("Handler does not export a fetch() function.");
    }
    return worker.fetch(request, env, ctx);
  }, "fetchDispatcher");
  return {
    ...worker,
    fetch(request, env, ctx) {
      const dispatcher = /* @__PURE__ */ __name(function(type, init) {
        if (type === "scheduled" && worker.scheduled !== void 0) {
          const controller = new __Facade_ScheduledController__(
            Date.now(),
            init.cron ?? "",
            () => {
            }
          );
          return worker.scheduled(controller, env, ctx);
        }
      }, "dispatcher");
      return __facade_invoke__(request, env, ctx, dispatcher, fetchDispatcher);
    }
  };
}
__name(wrapExportedHandler, "wrapExportedHandler");
function wrapWorkerEntrypoint(klass) {
  if (__INTERNAL_WRANGLER_MIDDLEWARE__ === void 0 || __INTERNAL_WRANGLER_MIDDLEWARE__.length === 0) {
    return klass;
  }
  for (const middleware of __INTERNAL_WRANGLER_MIDDLEWARE__) {
    __facade_register__(middleware);
  }
  return class extends klass {
    #fetchDispatcher = /* @__PURE__ */ __name((request, env, ctx) => {
      this.env = env;
      this.ctx = ctx;
      if (super.fetch === void 0) {
        throw new Error("Entrypoint class does not define a fetch() function.");
      }
      return super.fetch(request);
    }, "#fetchDispatcher");
    #dispatcher = /* @__PURE__ */ __name((type, init) => {
      if (type === "scheduled" && super.scheduled !== void 0) {
        const controller = new __Facade_ScheduledController__(
          Date.now(),
          init.cron ?? "",
          () => {
          }
        );
        return super.scheduled(controller);
      }
    }, "#dispatcher");
    fetch(request) {
      return __facade_invoke__(
        request,
        this.env,
        this.ctx,
        this.#dispatcher,
        this.#fetchDispatcher
      );
    }
  };
}
__name(wrapWorkerEntrypoint, "wrapWorkerEntrypoint");
var WRAPPED_ENTRY;
if (typeof middleware_insertion_facade_default === "object") {
  WRAPPED_ENTRY = wrapExportedHandler(middleware_insertion_facade_default);
} else if (typeof middleware_insertion_facade_default === "function") {
  WRAPPED_ENTRY = wrapWorkerEntrypoint(middleware_insertion_facade_default);
}
var middleware_loader_entry_default = WRAPPED_ENTRY;
export {
  __INTERNAL_WRANGLER_MIDDLEWARE__,
  middleware_loader_entry_default as default
};
//# sourceMappingURL=worker.js.map
