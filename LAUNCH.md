# Launch plan (draft, 17 Oct 2026)

Goal: credibility for Marc as a CTO who builds sharp tools for himself while building his company, and shares them and
what he learns. Free, open source (MIT, "as is", no warranty), fully local.

Positioning, one line: "Talk and point at your screen. Your coding agent gets the to-do list." Every text adds: built for
my own work while building [company]; I share the tools and what I learn.

## 1. What a stranger's Mac needs (before anything is public)

- Notarized and stapled build in a DMG (Developer ID is there; notarytool with the App Store Connect key), versioned, a
  GitHub Release per version. Auto-update (Sparkle) can wait for 0.2.
- First run asks before touching agent configs: "Connect Point to Claude Code, Codex, Cursor?" with the list; nothing is
  edited without that yes (today it connects on launch, fine for Marc only).
- No "Marc" in the MCP instructions, skill or texts ("the user"); bundle id and defaults neutral; build.sh without
  Marc's .env (identity from the environment).
- README: the 30 s video as a GIF at the top, install, the four permissions and why, "everything stays on your Mac",
  MCP tools, shell fallback, licence, disclaimer.
- A clean-Mac test: a new macOS user account installs from the DMG and records, an agent pulls and marks done.
- Name check before the repo and domain: "Point" is generic (no clash found among screen-to-agent tools; Annotate is the
  nearest product). Options: Point, pointer.dev, "Point for agents".

## 2. The site (one page)

Video first (autoplay, muted, loops), one line, one button (Download for Mac, Apple silicon, macOS 26), a 3-step how it
works, privacy line, GitHub link, "built by Marc while building [company]". Static, on Cloudflare Pages or Vercel.
Download count: the real number, from the GitHub Releases API (sum of `download_count`), cached hourly. It does not
start at 37 unless 37 people downloaded it (a made-up number is the one thing on the page that can cost credibility; HN
readers check).

## 3. The 30 s video

Motion film built in code (HTML frames rendered to MP4 with ffmpeg, or Remotion), example data only, Point's look:
1. A sample app with a visible bug (0 to 5 s).
2. Control twice: the pill appears (5 to 8 s).
3. The cursor rests on the button, a caption types what is said; then on a date (8 to 18 s).
4. Stop: the soft sound, "New in Point: 2 things to fix" on the clipboard (18 to 21 s).
5. A terminal: the agent calls get_open_items, edits, mark_done; the row turns Done (21 to 28 s).
6. End card: Point, free and open source, the URL (28 to 30 s).
Also a 6 s loop for X and the README GIF.

## 4. Launch sequence (one week)

- Day 0: repo public, site live, release notarized.
- Day 1 (Tue or Wed, 08:00 to 09:00 PT): Show HN "Show HN: Point, talk and point at your screen, your coding agent gets
  the to-do list" with a first comment on why and how (local, MCP, queue). Marc answers every comment for the first hours.
- Same day: X thread with the native video (not a link first; the link in a reply), tagging nobody it does not involve.
- Day 2 to 3: Product Hunt (12:01 PT, a maker comment, the video as the first asset).
- Week: MCP directories (Glama, mcp.so, Smithery, MCP Market), awesome-mcp-servers and awesome-claude-code pull requests,
  Homebrew cask, r/ClaudeAI, r/cursor, r/macapps, the Claude Code and Codex communities, newsletters (TLDR, Ben's Bites,
  Latent Space) with the video.

## 5. What builds followers and stars that last

- Build in public: one short post per real thing learned while building (a number, a screenshot, a failure). The tool is
  the proof, the posts are the reason to follow.
- Make the repo easy to star: GIF first, one-command install, issue templates, "good first issue" labels, fast replies,
  a changelog, releases people can watch.
- Reply-first on X: useful answers under posts in the agent-tools space, linking only when it helps.
- Ship a second small tool the same way in a few weeks; a series ("tools I build for myself") compounds.
- Not: bought stars or followers, vote rings, asking friends to upvote on HN (it is detected and flags the post), fake
  numbers. Each costs exactly the credibility the launch is for.

## Later: older Macs (Marc, 17 Oct 2026: macOS 26 and Apple silicon only for the launch)

Only speech-to-text needs macOS 26 (SpeechAnalyzer); everything else runs on macOS 14 (ScreenCaptureKit stills,
SMAppService, SwiftUI). To widen: SFSpeechRecognizer on device as the fallback below 26 (word times from its segments),
`platforms: [.macOS(.v14)]` and LSMinimumSystemVersion 14.0, a universal build (`--arch arm64 --arch x86_64`), CI on
macos-14, macos-15 and macos-26, and the installer's and the cask's checks relaxed to match.
