// Renders film.html frame by frame in headless Chrome and encodes the launch media with ffmpeg.
// node build.mjs [full|loop|poster|all]   (default all)
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import { mkdirSync, statSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const media = path.join(here, '..', 'public', 'media');
const out = path.join(here, 'out');
mkdirSync(media, { recursive: true }); mkdirSync(out, { recursive: true });
const FPS = 30;
const what = process.argv[2] || 'all';

const browser = await chromium.launch({ channel: 'chrome' });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });

async function open(mode) {
  await page.goto(pathToFileURL(path.join(here, 'film.html')).href + `?mode=${mode}&capture=1`);
  await page.evaluate(() => window.ready);
  return page.evaluate(() => window.DURATION);
}

function ffmpeg(args) {
  const p = spawn('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...args], { stdio: ['pipe', 'inherit', 'inherit'] });
  const done = new Promise((ok, fail) => p.on('close', c => (c ? fail(new Error('ffmpeg ' + c)) : ok())));
  return { stdin: p.stdin, done };
}

// Every frame as PNG into one ffmpeg, which writes a lossless master; the deliverables are cut from it.
async function capture(mode, master) {
  const duration = await open(mode);
  const n = Math.round(duration * FPS);
  const f = ffmpeg(['-f', 'image2pipe', '-framerate', String(FPS), '-i', '-', '-c:v', 'libx264rgb', '-crf', '0', '-preset', 'ultrafast', master]);
  for (let i = 0; i < n; i++) {
    await page.evaluate(t => window.render(t), i / FPS);
    const png = await page.screenshot({ type: 'png' });
    if (!f.stdin.write(png)) await new Promise(r => f.stdin.once('drain', r));
    if (i % FPS === 0) process.stdout.write(`\r${mode} ${i / FPS}s / ${duration}s`);
  }
  f.stdin.end(); await f.done; process.stdout.write('\n');
}

const h264 = ['-c:v', 'libx264', '-preset', 'veryslow', '-tune', 'animation', '-pix_fmt', 'yuv420p', '-profile:v', 'high', '-movflags', '+faststart', '-an'];
const size = f => (statSync(f).size / 1e6).toFixed(2) + ' MB';

if (what === 'all' || what === 'full') {
  const master = path.join(out, 'full-master.mkv');
  await capture('full', master);
  const mp4 = path.join(media, 'point-and-yap.mp4');
  await ffmpeg(['-i', master, ...h264, '-crf', '24', mp4]).done;
  console.log('point-and-yap.mp4', size(mp4));
}
if (what === 'all' || what === 'loop') {
  const master = path.join(out, 'loop-master.mkv');
  await capture('loop', master);
  const mp4 = path.join(media, 'point-and-yap-loop.mp4');
  await ffmpeg(['-i', master, ...h264, '-crf', '24', mp4]).done;
  const gif = path.join(media, 'point-and-yap-loop.gif');
  await ffmpeg(['-i', master, '-vf', 'fps=15,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=4', '-loop', '0', gif]).done;
  console.log('point-and-yap-loop.mp4', size(mp4), '· gif', size(gif));
}
if (what === 'all' || what === 'poster') {
  await open('full');
  await page.evaluate(() => window.render(6.6));
  const poster = path.join(media, 'point-and-yap-poster.jpg');
  await page.screenshot({ path: poster, type: 'jpeg', quality: 86 });
  console.log('point-and-yap-poster.jpg', size(poster));
}
// node build.mjs stills full 2,6.6,21  -> out/full-2.png ... for checking frames by eye.
if (what === 'stills') {
  const mode = process.argv[3] || 'full';
  await open(mode);
  for (const t of (process.argv[4] || '0').split(',').map(Number)) {
    await page.evaluate(t => window.render(t), t);
    await page.screenshot({ path: path.join(out, `${mode}-${t}.png`) });
  }
}
await browser.close();
