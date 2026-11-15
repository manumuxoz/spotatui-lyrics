# Architecture

## Goals

- Show the best available lyrics for the track currently playing in spotatui, especially when the source is YouTube.
- Prefer real timestamps; fall back to readable plain text instead of showing nothing.
- Recover from YouTube metadata that is a video title + channel name, not a song credit.
- Stay inside spotatui's Lua plugin API v6: no fork, no native code, no extra binaries.
- Keep the UI responsive and the network footprint small.

## Non-goals

- Replacing spotatui's built-in lyrics view. The plugin API cannot inject lyrics into it; a plugin gets its own screen.
- Downloading audio, aligning audio to text, or generating word-level karaoke timing.
- Scraping arbitrary websites. Providers are explicit modules with small, auditable endpoints.
- Bundling or persisting lyrics. The plugin is a client, not a lyrics database.

## Runtime constraints

The design is shaped by spotatui 0.48 / scripting API v6:

- Lua 5.4 (`mlua`) with the safe standard library, no sandbox and no memory limit.
- One Lua callback can run for at most about one second; a callback that errors is disabled after the first failure ("one strike").
- HTTP is asynchronous. `http_get` has no headers; `http_post` has headers but is POST-only. Requests time out after 30 s and the response body is read whole.
- Timers fire from the UI tick (250 ms by default). There is no per-frame draw callback and no terminal-size API.
- A plugin screen is retained-mode: `set_screen` replaces widgets, the app renders them. The screen has a fixed title/border and no playbar.
- `B` is consumed by the built-in `lyrics_view` before `on_key`; a `plugin_commands` binding on `B` is discarded unless the user remaps `lyrics_view`.
- `spotatui.playback()` inside a timer returns the previous tick's snapshot. The engine therefore adds one UI tick to the progress used for the highlight by default (≈250 ms); `SPOTATUI_LYRICS_BIAS_MS` overrides it. `t` calibrates the offset exactly, and `,`/`.` provide 50 ms nudges.

## Module map

```
main.lua                 entry point: requires API 6, wires engine + UI, events
ytlyrics/
  config.lua             environment settings, provider/source enablement
  util.lua               UTF-8, accent folding, URL/HTML encoding, table helpers
  metadata.lua           YouTube title repair and query variants
  lrc.lua                LRC parser, line index, plain-text timeline estimator
  score.lua              similarity, duration and combined match scoring
  http.lua               thin async wrapper + JSON decoding/body limits
  cache.lua              bounded in-memory LRU
  engine.lua             lookup state machine, provider race, cancellation
  ui.lua                 custom screen, keys, gauge, offset, debug popup
  i18n.lua               English/Spanish UI strings
  providers/
    lrclib.lua           synced LRC from LRCLIB
    lrcmux.lua           LRCLIB-compatible aggregator (lrcmux)
    youtube_music.lua    exact videoId -> InnerTube timed lyrics
    netease.lua          synced LRC/YRC from NetEase
    genius.lua           plain text from Genius
tests/
  harness.lua            mock spotatui API v6
  run.lua                dependency-free test runner
  test_*.lua             unit + integration tests
```

Module names are prefixed with `ytlyrics` because spotatui shares `package.path` and the module cache across plugins. A generic `util` or `config` would collide with another plugin.

## Lookup flow

```
track_change / open screen
        │
        ▼
metadata.parse(track) ──► info { title, artist, queries, is_music, debug }
        │
        ▼
variant/offset from storage
        │
        ▼
cache hit? ── yes ──► apply and render
        │ no
        ▼
generation++, status=loading, deadline timer
        │
        ▼
for query in ordered queries (max 4 by default):
  start every configured provider in parallel for the query
  score each result as it arrives
  show the first usable result as provisional (status ready + searching)
  upgrade it if a better synced result arrives
  stop on high-confidence synced, or a very strong plain result
        │
        ▼
choose best synced / plain / low-confidence
parse plain text into estimated lines
apply offset, cache in memory, render
```

A generation token is incremented for every new lookup. Every provider callback checks it, so a late answer for a skipped track is discarded. The lookup also has an overall timeout (`SPOTATUI_LYRICS_TIMEOUT`, default 15 s) that applies the best result collected so far.

The first result above the display threshold is applied immediately with `provisional=true` and `searching=true`. The engine keeps the race running; a later synced result replaces it with `provisional=false`. Only final results are cached. This is what makes opening the screen feel instant without giving up timestamp coverage.

After the first open, `SPOTATUI_LYRICS_WARM` (default on) prefetches the next YouTube tracks while the app runs, so reopening is a cache hit. Set it to `0` to return to strictly on-demand lookups.

## Metadata repair

`metadata.parse` is deliberately layered instead of one giant regex:

1. **Unescape and normalize** HTML entities, NBSP, zero-width characters, whitespace.
2. **Detect version hints** on the raw title (`live`, `remix`, `acoustic`, `cover`, `instrumental`, `karaoke`, `sped up`, `nightcore`).
3. **Extract credits**: `feat.` / `ft.` / `featuring`, `prod. by`.
4. **Remove bracketed noise** only when the bracket content starts with a known tag (`(Official Video)`, `[Lyric Video]`, `(4K Remaster)`, `【MV】`, …). Unknown parentheses such as `(I Can't Get No)` are preserved.
5. **Remove edge phrases** (`official music video`, `audio oficial`, `en vivo`, `letra`, …) and generic trailing words (`official`, `video`, `lyrics`, `HD`, …) only at the end.
6. **Strip version suffixes after a dash** (`Song - Live`, `Song – Remix`) while leaving `Live and Let Die` alone.
7. **Split artist/title** on spaced dashes, `//`, `|`, or quoted K-pop shapes (`BTS 'Dynamite'`). Both `Artist - Song` and `Song - Artist` are kept as candidates; the primary is chosen by which side looks like a credit/noise token.
8. **Clean the channel**: remove `VEVO`, `- Topic`, trailing `Music`/`Records`/`HD`, detect curator channels (`7clouds`, `MrSuicideSheep`, lyric channels, labels).
9. **Build queries** in priority order:
   1. clean title + primary artist,
   2. raw title + raw channel (LRCLIB often stores the exact YouTube row),
   3. swapped artist/title,
   4. clean title + non-curator channel,
   5. clean title + featured artist,
   6. alternate title variants + artist,
   7. title-only.

A video is marked non-music for durations under 30 s, 20 minutes or longer, or titles/channels that look like podcasts, tutorials, reactions, reviews, etc. `r` forces a lookup anyway.

## Scoring

`score.lua` computes:

- **Title similarity** — exact normalized match, containment, Jaccard token overlap and Levenshtein ratio. Result titles are cleaned of version tags, and both sides of a spaced dash are considered, so a raw `Daft Punk - Get Lucky (Official Audio)` row can match the query `Get Lucky`.
- **Artist similarity** — exact/contains/token overlap; collaborator lists are split; curator channels are neutral (0.5) because they are not the performing artist.
- **Duration similarity** — 1.0 within 2 s, 0.9 within 5 s, 0.75 within 10 s, 0.55 within 20 s, 0.35 within 35 s, 0.1 beyond. Unknown durations are neutral (0.5).

Default weights: title 55%, artist 25%, duration 20%. When the query artist is empty or a curator, the weights become title 70%, duration 30%.

Durations more than 15/30/60 s away are penalized (0.9/0.75/0.6) because a longer album version's timestamps do not fit a YouTube edit.

A result is accepted when the total is at least 0.68 (plain) or a synced result is close enough to the best plain result. A low-confidence result (>= 0.55) is still shown with a warning rather than showing nothing. A high-confidence synced result stops the race early; a strong plain result stops it after all providers for the current query have been tried.

## Providers

Each provider is a table with `name`, `id` and:

```lua
function provider.search(query, ctx, done)
  -- ctx.http       ytlyrics.http wrapper
  -- ctx.config     resolved configuration
  -- ctx.max_body_bytes
  -- ctx.debug      array of debug lines
  -- ctx.is_cancelled()
  -- done(results, errors)
end
```

A result has:

```lua
{
  provider = "LRCLIB",
  provider_id = "lrclib",
  title = "Get Lucky",
  artist = "Daft Punk",
  duration_ms = 249000,
  synced = true,             -- or false
  lines = { { time_ms = 12000, text = "..." } }, -- synced
  plain_text = "...",        -- plain
  url = "https://...",
}
```

Providers never render and never decide the final answer; the engine scores and selects.

## Caching and persistence

- **In-memory LRU** keyed by `uri#variant`, 24 entries. A resolved answer is reused until the track changes or `r` forces a reload.
- **Persistent** only:
  - `offset:<video_id>` — integer milliseconds (and the calibration result),
  - `variant:<video_id>` — chosen metadata variant.
- Lyrics are never persisted. This keeps the JSON store small and avoids writing copyrighted text to disk.

## UI

`ui.lua` registers one screen (`ytlyrics`) with three regions:

- fixed header (track + provider/status/offset/match),
- lyric window (`2 * context + 1` lines, current line highlighted with `▸`, past lines dim),
- a playback-control hint row, a playbar-shaped progress row (`⣿`/`⣉` halves, time, remaining) and a two-line footer.

A single 150 ms interval updates the screen; the render key avoids redundant `set_screen` calls when neither the line, the status, the offset nor the progress second changed. `set_screen` is wrapped in `pcall` so a malformed widget cannot disable the timer.

Keys are handled in `on_key`; `Esc`/`q` are global. `Enter` is consumed globally, so seek uses `s`. `B`/`ctrl+b` are consumed globally, hence the documented remap to `B` + `ctrl+b` with the built-in moved to `F2`. `t` calibrates the selected line to the current progress; `,`/`.` are 50 ms nudges, `[`/`]` 250 ms, `{`/`}` 1 s, `0` resets.

## Native playbar

`patches/0001-playbar-on-plugin-screens.patch` changes `draw_plugin_screen` to split the terminal with `fullscreen_view_layout` and call the existing `draw_playbar`, then adds `native_playbar: true` to the plugin config snapshot. `ui.lua` checks `config().behavior.native_playbar`; when true it publishes only lyrics + a compact status/help line and lets the real playbar render below. When false (official binary), it keeps the fallback controls/progress row.

## Why not `spotatui.get_lyrics`?

`get_lyrics` reads the result of spotatui's own lookup, which uses the raw title/channel and LRCLIB only. For YouTube that is exactly the problem. It also returns only `{status, lines}`, does not say whether timestamps are real, and times out after 15 s. The plugin performs its own lookup so it can clean metadata, try multiple providers and know whether the result is synced.

## Why not `yt-dlp` metadata?

`yt-dlp --dump-json` can expose `track`/`artist` fields, but from Lua it is a blocking process. The documented pattern (background shell + temp file + timer polling) is platform-specific, adds latency and failure modes, and requires quoting video IDs carefully. The parser plus provider matching covers the common cases without it. A future optional provider could add it behind a setting.

## Why not YouTube Music timed lyrics?

YouTube Music's InnerTube API has better `videoId` matching and often has timestamps for audio/Topic entities, but it is a private, unofficial API with region/experiment variability and Terms of Service risk. It is deliberately out of v1. If added, it should be opt-in and fall back to LRCLIB.

## Error handling

- Every event handler is wrapped by `main.lua`'s `guard`; a transient error logs instead of permanently disabling the event.
- The UI timer wraps its body in `pcall`.
- Provider callbacks never raise to the engine: parsing is protected and errors become `errors[]`.
- A provider error is displayed only in the debug popup, not as a modal; the other providers continue racing.
- HTTP bodies are capped before JSON decoding (`SPOTATUI_LYRICS_MAX_BODY`).

## Testing

`tests/run.lua` is a dependency-free Lua 5.4 runner. `tests/harness.lua` implements the subset of API v6 the plugin uses:

- playback/current track,
- async HTTP with route matching and deferred responses,
- timers and `advance(ms)`,
- commands, screens, widgets, events, storage, config, popups, seek.

The suite covers metadata shapes, LRC parsing, estimation, scoring, provider parsing, the Genius fallback, engine cancellation/caching/variants/timeouts, and a full plugin load that renders a simulated YouTube track. `scripts/smoke.sh` is a live network check, intentionally outside CI.
