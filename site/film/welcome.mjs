// Renders welcome.html (the first-run loop) at 2x: node welcome.mjs [stills t1,t2,...]
// Writes Resources/Welcome/welcome.mp4 (for the app) and welcome.gif (a preview), from a lossless master in out/.
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import { mkdirSync, statSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const dest = path.join(here, '..', '..', 'Resources', 'Welcome');
const out = path.join(here, 'out');
mkdirSync(dest, { recursive: true }); mkdirSync(out, { recursive: true });
const FPS = 30;
const browser = await chromium.launch({ channel: 'chrome' });
const page = await browser.newPage({ viewport: { width: 352, height: 220 }, deviceScaleFactor: 2 });
await page.goto(pathToFileURL(path.join(here, 'welcome.html')).href + '?capture=1');
await page.evaluate(() => window.ready);
const duration = await page.evaluate(() => window.DURATION);

function ffmpeg(args) {
  const p = spawn('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...args], { stdio: ['pipe', 'inherit', 'inherit'] });
  return { stdin: p.stdin, done: new Promise((ok, fail) => p.on('close', c => (c ? fail(new Error('ffmpeg ' + c)) : ok()))) };
}

if (process.argv[2] === 'stills') {
  for (const t of process.argv[3].split(',').map(Number)) {
    await page.evaluate(t => window.render(t), t);
    await page.screenshot({ path: path.join(out, `welcome-${t}.png`) });
    console.log(`out/welcome-${t}.png`);
  }
} else {
  const master = path.join(out, 'welcome-master.mkv');
  const f = ffmpeg(['-f', 'image2pipe', '-framerate', String(FPS), '-i', '-', '-c:v', 'libx264rgb', '-crf', '0', '-preset', 'ultrafast', master]);
  for (let i = 0; i < Math.round(duration * FPS); i++) {
    await page.evaluate(t => window.render(t), i / FPS);
    const png = await page.screenshot({ type: 'png' });
    if (!f.stdin.write(png)) await new Promise(r => f.stdin.once('drain', r));
  }
  f.stdin.end(); await f.done;
  const mp4 = path.join(dest, 'welcome.mp4'), gif = path.join(dest, 'welcome.gif');
  await ffmpeg(['-i', master, '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '20', '-preset', 'slow', '-movflags', '+faststart', '-an', mp4]).done;
  await ffmpeg(['-i', master, '-vf', 'fps=20,split[a][b];[a]palettegen=max_colors=96:stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=4', '-loop', '0', gif]).done;
  const kb = p => Math.round(statSync(p).size / 1024) + ' KB';
  console.log('welcome.mp4', kb(mp4), '· welcome.gif', kb(gif));
}
await browser.close();
