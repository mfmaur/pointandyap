#!/usr/bin/env node
// Who comes to Point and Yap, from where, and how many download and use it.
//   node scripts/stats.mjs             the report (last 30 days)
//   node scripts/stats.mjs --snapshot  saves today's GitHub numbers (GitHub keeps traffic only 14 days); run daily
// Needs: gh logged in (GitHub), CLOUDFLARE_API_TOKEN with Account Analytics read (site numbers; from the environment or
// the env file POINTANDYAP_ENV). Snapshots go to POINTANDYAP_STATS_DIR (default ~/.pointandyap-stats).
import { execFileSync } from "node:child_process";
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const REPO = "mfmaur/pointandyap";
const ACCOUNT = "c0d4f5623f4ed222585b3ff7782789ec";
const DIR = process.env.POINTANDYAP_STATS_DIR ?? join(homedir(), ".pointandyap-stats");
if (!process.env.CLOUDFLARE_API_TOKEN && process.env.POINTANDYAP_ENV) {
  for (const line of readFileSync(process.env.POINTANDYAP_ENV, "utf8").split("\n")) {
    const m = /^\s*(?:export\s+)?CLOUDFLARE_API_TOKEN=["']?([^"'\s]+)/.exec(line);
    if (m) process.env.CLOUDFLARE_API_TOKEN = m[1];
  }
}

const gh = (path, accept = "application/vnd.github+json") =>
  JSON.parse(execFileSync("gh", ["api", "-H", `Accept: ${accept}`, "--paginate", "--slurp", path], { encoding: "utf8" })).flat();
const gh1 = (path) => JSON.parse(execFileSync("gh", ["api", path], { encoding: "utf8" }));

function github() {
  const repo = gh1(`repos/${REPO}`);
  const releases = gh(`repos/${REPO}/releases?per_page=100`);
  return {
    at: new Date().toISOString(),
    stars: repo.stargazers_count, forks: repo.forks_count, watchers: repo.subscribers_count,
    views: gh1(`repos/${REPO}/traffic/views`), clones: gh1(`repos/${REPO}/traffic/clones`),
    referrers: gh1(`repos/${REPO}/traffic/popular/referrers`), paths: gh1(`repos/${REPO}/traffic/popular/paths`),
    downloads: releases.flatMap((r) => r.assets.map((a) => ({ tag: r.tag_name, name: a.name, count: a.download_count }))),
    starred: gh(`repos/${REPO}/stargazers?per_page=100`, "application/vnd.github.star+json").map((s) => s.starred_at),
  };
}

async function sql(query) {
  const r = await fetch(`https://api.cloudflare.com/client/v4/accounts/${ACCOUNT}/analytics_engine/sql`, {
    method: "POST", headers: { Authorization: `Bearer ${process.env.CLOUDFLARE_API_TOKEN}` }, body: query,
  });
  if (!r.ok) throw new Error(`analytics engine ${r.status}: ${(await r.text()).slice(0, 200)}`);
  return (await r.json()).data;
}

const table = (rows, cols) => {
  if (!rows.length) return "  (none yet)";
  const w = cols.map((c) => Math.max(c.length, ...rows.map((r) => String(r[c] ?? "").length)));
  return [cols.map((c, i) => c.padEnd(w[i])).join("  "), ...rows.map((r) => cols.map((c, i) => String(r[c] ?? "").padEnd(w[i])).join("  "))]
    .map((l) => "  " + l).join("\n");
};

if (process.argv.includes("--snapshot")) {
  mkdirSync(DIR, { recursive: true });
  const file = join(DIR, `${new Date().toISOString().slice(0, 10)}.json`);
  writeFileSync(file, JSON.stringify(github(), null, 2));
  console.log(`saved ${file}`);
  process.exit(0);
}

// GitHub: today's numbers, plus every saved day so views older than 14 days are not lost.
const now = github();
const byDay = new Map();
const files = (() => { try { return readdirSync(DIR).filter((f) => f.endsWith(".json")).sort(); } catch { return []; } })();
for (const snap of [...files.map((f) => JSON.parse(readFileSync(join(DIR, f), "utf8"))), now]) {
  for (const v of snap.views.views) byDay.set(v.timestamp.slice(0, 10), { ...byDay.get(v.timestamp.slice(0, 10)), day: v.timestamp.slice(0, 10), views: v.count, visitors: v.uniques });
  for (const c of snap.clones.clones) byDay.set(c.timestamp.slice(0, 10), { ...byDay.get(c.timestamp.slice(0, 10)), day: c.timestamp.slice(0, 10), clones: c.count });
}
for (const t of now.starred) { const d = t.slice(0, 10); byDay.set(d, { ...byDay.get(d), day: d, stars: (byDay.get(d)?.stars ?? 0) + 1 }); }
const dmg = now.downloads.filter((d) => d.name.endsWith(".dmg"));

console.log(`Point and Yap, ${now.at.slice(0, 16).replace("T", " ")} UTC\n`);
console.log(`GitHub: ${now.stars} stars, ${now.forks} forks, ${now.watchers} watching; DMG downloads ${dmg.reduce((s, d) => s + d.count, 0)} (${dmg.map((d) => `${d.tag} ${d.count}`).join(", ")})`);
console.log("\nGitHub repo per day (views and visitors kept 14 days by GitHub, longer from the daily snapshots)");
console.log(table([...byDay.values()].sort((a, b) => a.day.localeCompare(b.day)).slice(-30), ["day", "views", "visitors", "clones", "stars"]));
console.log("\nGitHub referrers (14 days)");
console.log(table(now.referrers, ["referrer", "count", "uniques"]));
console.log("\nGitHub pages (14 days)");
console.log(table(now.paths.map((p) => ({ ...p, path: p.path.replace(`/${REPO}`, "") || "/" })), ["path", "count", "uniques"]));

if (!process.env.CLOUDFLARE_API_TOKEN) { console.log("\n(site numbers need CLOUDFLARE_API_TOKEN)"); process.exit(0); }
const SINCE = "timestamp > NOW() - INTERVAL '30' DAY AND blob6 != 'bot'";
const days = await sql(`SELECT toDate(timestamp) AS day, blob1 AS event, SUM(_sample_interval) AS n, COUNT(DISTINCT blob7) AS people
  FROM pointandyap_events WHERE ${SINCE} GROUP BY day, event ORDER BY day FORMAT JSON`);
const perDay = new Map();
for (const r of days) perDay.set(r.day, { ...perDay.get(r.day), day: r.day, [r.event]: r.n, [`${r.event}_people`]: r.people });
console.log("\npointandyap.com per day (visitors = distinct per day; bots left out)");
console.log(table([...perDay.values()].map((d) => ({ day: d.day, views: d.view, visitors: d.view_people, downloads: d.download,
  installs: d.install, "copies in use": d.update_check_people })), ["day", "views", "visitors", "downloads", "installs", "copies in use"]));
console.log("\nWhere visitors and downloads come from (30 days)");
console.log(table((await sql(`SELECT blob1 AS event, blob3 AS referrer, blob4 AS ref, SUM(_sample_interval) AS n
  FROM pointandyap_events WHERE ${SINCE} AND blob1 IN ('view', 'download')
  GROUP BY event, referrer, ref ORDER BY n DESC LIMIT 20 FORMAT JSON`))
  .map((r) => ({ ...r, source: r.ref ? `ref=${r.ref}` : r.referrer || "direct" })), ["event", "source", "n"]));
console.log("\nCountries (views, 30 days)");
console.log(table(await sql(`SELECT blob5 AS country, SUM(_sample_interval) AS views, COUNT(DISTINCT blob7) AS visitors
  FROM pointandyap_events WHERE ${SINCE} AND blob1 = 'view' GROUP BY country ORDER BY views DESC LIMIT 15 FORMAT JSON`), ["country", "views", "visitors"]));
console.log("\nCopies in use by version (distinct update checks, last 2 days)");
console.log(table(await sql(`SELECT blob8 AS version, COUNT(DISTINCT blob7) AS copies FROM pointandyap_events
  WHERE timestamp > NOW() - INTERVAL '2' DAY AND blob1 = 'update_check' AND blob6 = 'app' GROUP BY version ORDER BY copies DESC FORMAT JSON`), ["version", "copies"]));
