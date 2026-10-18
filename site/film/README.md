# The launch film

`film.html` draws one 1920x1080 frame of the Point and Yap film for any time `t`. Nothing is random and nothing depends on
the clock, so every frame can be rebuilt exactly. `build.mjs` steps through the frames in headless Chrome (Playwright) and
encodes them with ffmpeg. Example data only: the app on screen is a made-up "Acme" settings window.

## Rebuild

Needs Node 20+, ffmpeg on the PATH and Google Chrome installed (Playwright drives it; no browser download). The fonts load
from Google Fonts, so it needs the network.

```bash
cd site/film
npm install
node build.mjs          # everything, about 2 minutes
node build.mjs full     # only the 30 s film
node build.mjs loop     # only the 6 s loop (MP4 and GIF)
node build.mjs poster   # only the poster frame
```

It writes to `site/public/media/`:

| File | What |
| --- | --- |
| `point-and-yap.mp4` | the 30 s film, 1920x1080, 30 fps, H.264, no audio, under 0.5 MB |
| `point-and-yap-poster.jpg` | the frame at 6.6 s (pointing at Save), the video's poster on the site |
| `point-and-yap-loop.mp4` | the 6 s seamless loop, 1920x1080 |
| `point-and-yap-loop.gif` | the same loop, 960x540, 15 fps, for the README and X |

Lossless masters go to `out/` (not in git) and the deliverables are cut from them.

## Look at it

- Open `film.html?mode=full` (or `?mode=loop`) in a browser to watch it play in real time, scaled to the window.
- `film.html?mode=full&t=21.5` freezes one frame.
- `node build.mjs stills full 2,6.6,21` writes `out/full-2.png` and so on, to check frames by eye before a full render.

## The story (seconds)

| t | |
| --- | --- |
| 0.9 to 3 | Control pressed twice; the recording pill drops in |
| 3.4 to 8.6 | the cursor rests on the grey Save button, gold ring, "This button should be blue." |
| 8.6 to 13.4 | the cursor rests on "3 days ago", "And this date should say today." |
| 14.3 | Stop |
| 15 to 17 | "New in Point and Yap: 2 things to fix" |
| 17 to 24 | the queue and a coding agent: `get_open_items`, two edits (Save turns blue, the date reads "Today"), `mark_done`, rows read Done |
| 25.6 to 30 | end card: Point and Yap. Show, don’t type. pointandyap.com |

The loop is drawn from a 7 s source; its last second is blended over its first, so the last frame flows into the first.

Edit the timings in `renderFull` / `renderLoop` and the terminal lines in `TERM_FULL` / `TERM_LOOP`. Copy rules: no em
dashes, sentence case.

## The first-run loop

`welcome.html` is the 9 s loop the app shows above Start recording (352 x 220 pt). `node welcome.mjs` renders it at 2x
into `Resources/Welcome/welcome.mp4` (the app plays it) and `welcome.gif` (a preview); `node welcome.mjs stills 3.6`
writes single frames to `out/`. The poster `Resources/Welcome/welcome-poster.png` is the frame at 3.6 s.

