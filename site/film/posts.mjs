// Renders posts.html (the clips for the posts after launch) to MP4 in out/, like build.mjs does the film.
// node posts.mjs [before|session|this|all]      node posts.mjs stills before 3,10,14
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import { mkdirSync, statSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, 'out');
mkdirSync(out, { recursive: true });
const FPS = 30;
const what = process.argv[2] || 'all';

const browser = await chromium.launch({ channel: 'chrome' });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
async function open(mode) {
  await page.goto(pathToFileURL(path.join(here, 'posts.html')).href + `?mode=${mode}&capture=1`);
  await page.evaluate(() => window.ready);
  return page.evaluate(() => window.DURATION);
}
function ffmpeg(args) {
  const p = spawn('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...args], { stdio: ['pipe', 'inherit', 'inherit'] });
  return { stdin: p.stdin, done: new Promise((ok, fail) => p.on('close', c => (c ? fail(new Error('ffmpeg ' + c)) : ok()))) };
}
const h264 = ['-c:v', 'libx264', '-preset', 'veryslow', '-tune', 'animation', '-pix_fmt', 'yuv420p', '-profile:v', 'high', '-movflags', '+faststart', '-an', '-crf', '24'];

if (what === 'stills') {
  const mode = process.argv[3] || 'before';
  await open(mode);
  for (const t of (process.argv[4] || '0').split(',').map(Number)) {
    await page.evaluate(t => window.render(t), t);
    await page.screenshot({ path: path.join(out, `posts-${mode}-${t}.png`) });
  }
} else {
  for (const mode of what === 'all' ? ['before', 'session', 'this'] : [what]) {
    const duration = await open(mode), n = Math.round(duration * FPS);
    const mp4 = path.join(out, `posts-${mode}.mp4`);
    const f = ffmpeg(['-f', 'image2pipe', '-framerate', String(FPS), '-i', '-', ...h264, mp4]);
    for (let i = 0; i < n; i++) {
      await page.evaluate(t => window.render(t), i / FPS);
      const png = await page.screenshot({ type: 'png' });
      if (!f.stdin.write(png)) await new Promise(r => f.stdin.once('drain', r));
      if (i % FPS === 0) process.stdout.write(`\r${mode} ${i / FPS}s / ${duration}s`);
    }
    f.stdin.end(); await f.done; process.stdout.write('\n');
    await page.evaluate(t => window.render(t), { before: 10.8, session: 2.8, this: 4.6 }[mode]);
    await page.screenshot({ path: path.join(out, `posts-${mode}-poster.jpg`), type: 'jpeg', quality: 86 });
    console.log(mp4, (statSync(mp4).size / 1e6).toFixed(2) + ' MB');
  }
}
await browser.close();
