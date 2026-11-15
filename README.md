# spotatui-lyrics

**Synced lyrics for YouTube in [spotatui](https://github.com/LargeModGames/spotatui) — with metadata repair and provider fallbacks.**

[![CI](https://github.com/manumuxoz/spotatui-lyrics/actions/workflows/ci.yml/badge.svg)](https://github.com/manumuxoz/spotatui-lyrics/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![spotatui API v6](https://img.shields.io/badge/spotatui%20API-v6-1db954.svg)](https://spotatui.com/docs/scripting)

```
┌ Lyrics ──────────────────────────────────────────────────────┐
│♪ Guxo - Si El Mundo Fuera Perfecto                           │
│Guxo · Genius · text · estimated · offset +0 ms · match 1/4   │
│                                                              │
│  [Intro]                                                     │
│  First synthetic lyric line                                  │
│  Second synthetic lyric line                                 │
│  [Chorus]                                                    │
│▸ Current lyric line, highlighted                             │
│  Next synthetic lyric line                                   │
│  Another synthetic lyric line                                │
│  More placeholder text for the screenshot                    │
│  ...                                                         │
│                                                              │
│ p prev  ·  space play/pause  ·  n next  ·  < > seek          │
│ 0:35/3:33 (-2:58) ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣉⣉⣉⣉⣉⣉⣉⣉⣉⣉⣉⣉                │
│ j/k · f · s · t · [ ] · , . · m · r · i · Esc                │
│ Genius · match 1/4 · following                               │
└──────────────────────────────────────────────────────────────┘
```

## Why this exists

spotatui's built-in lyrics view asks LRCLIB for the **raw YouTube video title** and the **channel name**. That metadata is not a song credit:

- `Guxo - Si El Mundo Fuera Perfecto` → title `Guxo - Si El Mundo Fuera Perfecto`, artist `Guxo`
- `Daft Punk - Get Lucky (Lyrics) ft. Pharrell Williams` by channel `7clouds` → artist `7clouds`
- `Ella Baila Sola (Video Oficial)` by `DEL Records` → artist `DEL Records`

The built-in lookup often returns *"No lyrics for this track"* even when the song exists, and it cannot use a different provider. This plugin:

1. **Repairs the metadata** — strips `(Official Video)`, `[Lyric Video]`, `(4K Remaster)`, `ft.` credits, label/channel suffixes and more; splits `Artist - Song`, `Song - Artist`, quoted K-pop titles and pipe-separated album tags.
2. **Builds several queries** — clean title + artist, raw YouTube row, swapped artist/title, channel, featured artist, title variants and title-only.
3. **Asks several providers** — LRCLIB, lrcmux, YouTube Music, NetEase and Genius, racing in parallel.
4. **Scores the answers** — title, artist and duration, with a preference for real timestamps. A wrong song with perfect timestamps is worse than a right song with estimated timing.
5. **Shows a real lyric screen** — current line highlighted, auto-follow, manual scroll, seek to a line, per-video timing offset, match variants and a debug view.

There was no existing spotatui lyrics plugin that solved this when the project was started. The official `now-playing.lua` example proves the UI is possible, but it uses `spotatui.get_lyrics`, so it inherits the raw-metadata problem.

## Features

- **Line-synced lyrics when a provider has timestamps.**
- **Fast first paint**: providers race in parallel and the first usable answer is shown immediately; a synced answer upgrades it if one arrives later.
- **Readable plain lyrics when no provider has timestamps**, with a clearly labelled estimated timeline.
- **YouTube metadata repair** with multi-language noise tags (English, Spanish, Portuguese, Korean/Japanese title shapes).
- **Provider race** with per-provider parsing and graceful failure.
- **Match variants** (`m`): if the parser split the title wrong, try the next query without editing anything.
- **Timing calibration** (`t`): aligns the selected line with the current playback position in one keypress. Fine nudges (`,` / `.`), 250 ms steps, 1 s steps and reset are available; the offset is remembered per video.
- **Seek to a line** (`s`): jumps playback to the selected line.
- **Debug popup** (`i`): shows the raw metadata, every query, every HTTP request, every score and the selected provider. Useful for bug reports.
- **Lazy lookup**: nothing is fetched until you open the screen, unless `SPOTATUI_LYRICS_PREFETCH=1`.
- **In-memory cache**: no lyrics are written to disk.
- **English and Spanish UI**, following `LANG` or `SPOTATUI_LYRICS_LANG`.

## Install

Requirements:

- spotatui **0.48 or newer**, with the `scripting` feature (included in official release builds).
- `git` for `spotatui plugin add`.
- Network access to the providers you enable.

```bash
spotatui plugin add manumuxoz/spotatui-lyrics
```

Add a key binding in `$XDG_CONFIG_HOME/spotatui/config.yml` (usually `~/.config/spotatui/config.yml`):

```yaml
plugin_commands:
  ytlyrics_open: "ctrl-l"
```

Restart spotatui. Press `ctrl-l` on any YouTube track.

### Use `B` and `ctrl+b`

`B` and `ctrl+b` are consumed by spotatui's built-in `lyrics_view` by default. Move that view out of the way and bind both keys to the plugin:

```yaml
keybindings:
  lyrics_view: "f2"

plugin_commands:
  ytlyrics_open: "B"
  ytlyrics_open_alt: "ctrl-b"
```

Now `B` and `ctrl+b` both open the plugin screen; `F2` keeps the built-in view as a fallback. Restart after changing the config. If you leave `lyrics_view` on `B`/`ctrl-b`, spotatui logs a warning and skips the colliding plugin binding.

## Keys

| Key | Action |
|---|---|
| `j` / `Down` | Scroll down and pause auto-follow |
| `k` / `Up` | Scroll up and pause auto-follow |
| `f` | Resume auto-follow |
| `s` | Seek playback to the selected line |
| `t` | Calibrate: make the selected line start at the current playback position |
| `,` / `.` | Nudge lyric timing 50 ms earlier / later |
| `[` / `]` | Move lyric timing 250 ms earlier / later |
| `{` / `}` | Move lyric timing 1 s earlier / later |
| `0` | Reset the timing offset for this video |
| `m` | Try the next metadata/query variant |
| `r` | Retry and reset to match 1 |
| `i` | Open the debug popup |
| `Esc` / `q` | Back |

Auto-follow resumes by itself 8 seconds after the last scroll. The offset is stored per YouTube video ID.

For an exact calibration, pause or seek to the moment the line starts, select that line with `j`/`k`, and press `t`. While playing, the plugin compensates for its one-tick playback snapshot delay automatically.

## How it works

```
YouTube track
  │  name = full video title, artists = [channel]
  ▼
metadata.lua
  │  clean tags, split artist/title, channels, feat., variants
  ▼
engine.lua
  │  query 1..N, provider 1..M, generation token, 15 s deadline
  ▼
LRCLIB ─────────┐
  lrcmux ─────────┤
  YouTube Music ──┼──► race ──► first answer ──► upgrade if synced
  NetEase ────────┤
  Genius ─────────┘
        │
        ▼
score.lua: title 55% + artist 25% + duration 20%
  │  prefer synced; reject wrong songs; keep plain fallback
  ▼
ui.lua: custom screen, current line, gauge, offset, variants
```

Providers run in parallel. The first usable result is rendered immediately as a provisional answer; a high-confidence synced result stops the race, and a late synced answer upgrades the provisional one. A strong **plain** result is accepted when the remaining providers are unlikely to add timestamps, so the screen is not stuck loading for ten seconds. See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full data flow and API constraints.

## Providers

| Provider | Timestamps | Account / key | Status | Default |
|---|---|---|---|---|
| **LRCLIB** | Yes, line-synced LRC | None | Open, documented API | **On** |
| **lrcmux** | Yes (aggregated word/line timing) | None | Open MIT aggregator; public instance, 60 req/min | **On** |
| **YouTube Music** | Yes, when the art track has cue ranges | None | Unofficial InnerTube API; exact `videoId` | **On** |
| **NetEase Cloud Music** | Yes (LRC/YRC) | None | Unofficial web endpoints; may be geo-blocked | **On** |
| **Genius** | No (plain text) | None | Public web endpoint; no official lyrics API | **On** |

- **LRCLIB** is the primary source. The plugin sends an identifiable `spotatui/<version>` User-Agent through spotatui's HTTP client and keeps request counts low.
- **lrcmux** aggregates Deezer/KuGou/Musixmatch/YouTube Music/LRCLIB and returns LRCLIB-compatible LRC, often with word-level timing. The plugin downmixes it to line timing. It is MIT and self-hostable; the public instance is a convenience, not an SLA.
- **YouTube Music** resolves the exact video ID to its lyrics page. The Android Music client returns `timedLyricsModel` with `cueRange` for art tracks; official videos may only have text, in which case the plugin estimates the timeline. It is an unofficial InnerTube endpoint and can change; disable it with `SPOTATUI_LYRICS_PROVIDERS=lrclib,lrcmux,netease,genius` if you prefer not to use it.
- **Genius** is used for catalogue breadth. It has no timestamps, so the plugin estimates a readable timeline and labels it as such. The provider first uses spotatui's normal GET; if Genius blocks it, it retries with a browser UA through a POST method override. Disable that fallback with `SPOTATUI_LYRICS_GENIUS_POST=0`.
- **NetEase** is enabled by default for extra synced coverage, especially for Latin/Asian catalogues. It is an unofficial endpoint; disable it if you prefer LRCLIB + Genius only:

```bash
SPOTATUI_LYRICS_PROVIDERS=lrclib,genius spotatui
```

The providers are intentionally replaceable: adding one is a module with a `search(query, ctx, done)` function. See [`docs/PROVIDERS.md`](docs/PROVIDERS.md).

## Configuration

All settings are environment variables, read at plugin load time.

| Variable | Default | Meaning |
|---|---|---|
| `SPOTATUI_LYRICS_PROVIDERS` | `lrclib,lrcmux,ytmusic,netease,genius` | Comma-separated provider order. Remove providers you do not want (e.g. `lrclib,genius`). |
| `SPOTATUI_LYRICS_SOURCES` | `youtube` | `youtube` or `all` (also handle Spotify/local/Subsonic/Qobuz when the built-in lookup fails). |
| `SPOTATUI_LYRICS_PREFETCH` | `0` | `1` fetches lyrics on every track change, even before you open the screen. |
| `SPOTATUI_LYRICS_WARM` | `1` | After the first open, prefetch the next tracks so the screen opens instantly. `0` disables it. |
| `SPOTATUI_LYRICS_CONTEXT` | `6` | Lyric lines shown above and below the current one (2–20). |
| `SPOTATUI_LYRICS_OFFSET_STEP` | `250` | Offset step in ms for `[` / `]`. |
| `SPOTATUI_LYRICS_OFFSET_FINE` | `50` | Fine offset step in ms for `,` / `.`. |
| `SPOTATUI_LYRICS_BIAS_MS` | auto | Compensates for spotatui's one-tick playback snapshot delay. Auto is one UI tick (≈250 ms); set a number to override. |
| `SPOTATUI_LYRICS_TIMEOUT` | `15000` | Overall lookup deadline in ms. |
| `SPOTATUI_LYRICS_MAX_QUERIES` | `4` | Metadata variants tried per lookup (1–8). |
| `SPOTATUI_LYRICS_ESTIMATE` | `1` | Set `0` to show plain lyrics without an estimated timeline. |
| `SPOTATUI_LYRICS_LANG` | auto | `en` or `es`. Auto follows `LANG`/`LC_ALL`. |
| `SPOTATUI_LYRICS_GENIUS_POST` | `1` | `0` disables the browser-UA POST fallback for Genius. |
| `SPOTATUI_LYRICS_DEBUG` | `0` | `1` writes verbose lookup details to the app log. |
| `SPOTATUI_LYRICS_MAX_BODY` | `2097152` | Maximum response body size in bytes. |

Example:

```bash
export SPOTATUI_LYRICS_LANG=es
export SPOTATUI_LYRICS_CONTEXT=8
export SPOTATUI_LYRICS_PROVIDERS=lrclib,lrcmux,ytmusic,netease,genius
spotatui
```

PowerShell:

```powershell
$env:SPOTATUI_LYRICS_PROVIDERS = "lrclib,lrcmux,ytmusic,netease,genius"
spotatui
```

## Privacy and legal notes

- The plugin sends **track title, artist candidates and duration** to the providers you enable. There is no account, token, telemetry or analytics.
- Lyrics are held **in memory only**. Offsets and the chosen match variant are stored in spotatui's per-plugin JSON store; lyrics never are.
- Opening the screen is the consent point. Nothing is fetched before you first open it. After that, the plugin warms the next tracks so the screen opens instantly; set `SPOTATUI_LYRICS_WARM=0` to disable it.
- LRCLIB is an open community database; lrcmux is an open MIT aggregator (self-hostable). YouTube Music (InnerTube), Genius and NetEase are public web endpoints used by many lyrics clients; they can change, rate-limit or block requests at any time. Disable them if you prefer LRCLIB only.
- Lyrics are copyrighted by their authors and rights holders. This plugin displays them; it does not download, bundle, cache on disk or redistribute them. Respect the terms of the services you enable.
- This project is not affiliated with spotatui, Spotify, YouTube, LRCLIB, lrcmux, Genius or NetEase.

## Native playbar (recommended)

The plugin API cannot draw spotatui's global playbar on a plugin screen: plugin screens take the full terminal and the app's playbar is not rendered there. To reuse the **real** playbar instead of the plugin's compact fallback, this repository ships a small spotatui patch:

```bash
scripts/build-patched-spotatui.sh
cp ~/.local/bin/spotatui ~/.local/bin/spotatui-0.48.0-original
cp /tmp/opencode/spotatui-patched/target/release/spotatui ~/.local/bin/spotatui
```

Set `behavior.disable_auto_update: true` in your config so an official update does not replace the patched binary. The patch:

- renders the existing playbar below every plugin screen, using `fullscreen_view_layout` + `draw_playbar` (the same functions the built-in lyrics view uses);
- exposes `config().behavior.native_playbar = true` so this plugin hides its fallback controls and leaves the real playbar visible.

The patch is in [`patches/0001-playbar-on-plugin-screens.patch`](patches/0001-playbar-on-plugin-screens.patch) and builds against spotatui `v0.48.0`. Without the patch the plugin still works, with its compact fallback progress line.

## Limitations

- The plugin opens its **own screen**. spotatui's plugin API cannot inject lyrics into the built-in view or take over `B` without a config change.
- Without the patch, plugin screens do not draw the app's playbar, so the plugin shows a compact fallback progress line. With the patch, the real playbar is used below the screen.
- Genius has no timestamps. The timeline is estimated by line length and labelled `text · estimated`; `[`/`]` lets you correct it. A synced provider is always preferred when available.
- No provider has the song? The screen says so. `m` tries other metadata variants; `i` shows the exact queries and errors.
- The plugin does not run `yt-dlp` to enrich metadata. That would block the UI or add a process/file dependency; the title parser covers the common YouTube shapes.
- YouTube Music's timed lyrics depend on the exact entity: art tracks usually carry cue ranges, while some official videos only expose text. The provider falls back to an estimated timeline when cues are missing. The InnerTube endpoint is unofficial and can change.
- Very long videos (mixes, podcasts, streams) are skipped as non-music by default. Press `r` to search anyway.

## Troubleshooting

**No lyrics found**

1. Press `i` and read the debug popup: it shows the raw metadata, each query, each provider request and the scores.
2. Press `m` to try another metadata variant.
3. Press `r` to retry from match 1.
4. If you disabled NetEase, enable it for more synced coverage:
   `SPOTATUI_LYRICS_PROVIDERS=lrclib,ytmusic,netease,genius spotatui`
5. Check that the provider is reachable from your network.

**The plugin does not load**

Run the installer doctor:

```bash
~/.config/spotatui/plugins/spotatui-lyrics/scripts/doctor.sh
```

It checks the spotatui version, the installed files, `plugins.lock`, the `ytlyrics_open` binding, the running instance and the log. Add `--network` to test the provider endpoints too.

- Check the spotatui version: `spotatui --version` (0.48+).
- Check `spotatui plugin list`.
- Look at the log printed at startup (`Logging to: ...`); a load error appears as `plugin 'spotatui-lyrics' failed to load`.
- **Restart spotatui after installing or changing the config.** Plugins load at startup; a running instance that says `no lua plugin files found` will keep using the built-in lyrics view until restarted.

**The key does nothing**

- `B` collides with the built-in `lyrics_view`; see [Use `B`](#use-b-the-built-in-lyrics-key).
- Check that the command name is exactly `ytlyrics_open` under `plugin_commands`.
- Reserved keys (`H`, `M`, `L`, arrows, `Backspace`, `Enter`) cannot be bound to plugin commands.

**Timing is off**

- Use `[` / `]` for 250 ms steps, `{` / `}` for 1 s steps. The offset is stored per video.
- Press `0` to reset.
- If the lyrics are plain text, the timeline is an estimate; no amount of offset makes it exact.

**Wrong song**

- Press `m` to cycle the metadata variants (clean title, raw row, swapped artist/title, title-only).
- If none is right, the providers do not have a matching record; open an issue with the debug popup and the video URL.

More in [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

## Development

The plugin is plain Lua 5.4 with no external Lua dependencies.

```bash
git clone https://github.com/manumuxoz/spotatui-lyrics
cd spotatui-lyrics
lua5.4 tests/run.lua
```

The test suite uses a mock spotatui API (`tests/harness.lua`) and covers:

- metadata repair across YouTube title shapes,
- LRC parsing, offsets, headers and plain-text estimation,
- match scoring and provider selection,
- provider URL/response handling, including the Genius UA fallback,
- engine cancellation, caching, variants and timeouts,
- a full plugin load with a simulated YouTube track and rendered screen.

Install a development copy as a directory plugin:

```bash
ln -s "$PWD" "${XDG_CONFIG_HOME:-$HOME/.config}/spotatui/plugins/spotatui-lyrics"
```

Add the binding and restart. `scripts/smoke.sh` runs live HTTP checks against the five providers (requires `curl` and `jq`; not part of CI).

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the module map and design decisions.

## Prior art

The capabilities come from spotatui's Lua API v6 and the providers' public endpoints. Related projects worth a look:

- [spotatui](https://github.com/LargeModGames/spotatui) — the player and plugin host.
- [LRCLIB](https://lrclib.net) — open synced-lyrics database.
- [cloofy](https://github.com/parda21/cloofy) and [lrcmux](https://github.com/f1nniboy/lrcmux) — prior art for YouTube Music/LRCLIB matching.
- [LRCGET](https://github.com/tranxuanthang/lrcget) — LRCLIB client with a matching strategy.

## License

MIT. See [`LICENSE`](LICENSE). Lyrics are not part of this repository and remain the property of their rights holders.

---

**Español:** instalación rápida, teclas y configuración en [`README.es.md`](README.es.md).
