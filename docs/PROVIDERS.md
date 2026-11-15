# Providers

The plugin asks providers in the order set by `SPOTATUI_LYRICS_PROVIDERS` (default `lrclib,ytmusic,netease,genius`). A provider returns scored candidates; the engine decides which one to show.

All requests are HTTPS, asynchronous and bounded by spotatui's HTTP client. Response bodies are capped before JSON decoding. No provider is bundled with lyrics.

## LRCLIB

- Site: <https://lrclib.net>
- Base: `https://lrclib.net/api`
- Auth: none. LRCLIB asks clients to identify themselves; spotatui's shared HTTP client sends `spotatui/<version>`.
- Rate limits: roughly 45 req/min generic, 90 req/min identified, 180 req/min registered. Honor `429` and `Retry-After`; the plugin keeps each lookup to a few sequential requests and stops early.
- Timestamps: yes, line-synced LRC (`syncedLyrics`). Some records also have `plainLyrics`.

Endpoints used:

```
GET /api/get?track_name=Get%20Lucky&artist_name=Daft%20Punk&duration=249
GET /api/search?track_name=Get%20Lucky&artist_name=Daft%20Punk
GET /api/search?q=Get%20Lucky%20Daft%20Punk
```

`/api/get` is an exact signature match (title + artist + whole-second duration), so it 404s on small differences. The plugin then uses `/api/search`; when no artist match is found it retries with a free-text `q`.

Relevant response fields:

```json
{
  "id": 986804,
  "trackName": "Get Lucky",
  "artistName": "Daft Punk",
  "albumName": "Random Access Memories",
  "duration": 249,
  "instrumental": false,
  "plainLyrics": "...",
  "syncedLyrics": "[00:12.00]Synthetic lyric line\n..."
}
```

The provider prefers a synced record; a plain record is kept as a fallback while the engine tries the other providers. LRCLIB contains many rows whose `trackName` is the exact YouTube video title and whose `artistName` is the channel; the raw-metadata query is there to catch those.

## NetEase Cloud Music

- Status: unofficial web API; enabled by default.
- Auth: none for the endpoints below, but some regions/IPs are blocked or get different responses.
- Timestamps: LRC (`lrc.lyric`), sometimes word-level YRC (`yrc.lyric`) and karaoke LRC (`klyric.lyric`).

Search:

```
POST https://music.163.com/api/cloudsearch/pc
Content-Type: application/x-www-form-urlencoded
Referer: https://music.163.com/

s=Bad%20Bunny%20Tit%C3%AD%20Me%20Pregunt%C3%B3&type=1&limit=8&offset=0
```

Response fields: `result.songs[].id`, `.name`, `.ar[].name` (artists), `.al.name` (album), `.dt` (duration in ms). Older responses may use `.artists` and `.duration`.

Lyrics:

```
GET https://music.163.com/api/song/lyric?id=1944936667&lv=1&kv=1&tv=-1
```

Response: `lrc.lyric`, `yrc.lyric`, `klyric.lyric`. The provider strips `[00:00.000] 作曲 : ...`-style credits and parses the first usable format.

Enable it with:

```bash
SPOTATUI_LYRICS_PROVIDERS=lrclib,ytmusic,netease,genius spotatui
```

## YouTube Music (InnerTube)

- Status: unofficial private API; enabled by default.
- Auth: none. No cookie, API key or `visitorData` is required for the endpoints below (verified 2026-11-15).
- Timestamps: `timedLyricsModel.lyricsData.timedLyricsData[].cueRange` when the entity has them. Some official videos expose the same model without `cueRange`; those become plain text and the engine estimates a timeline.
- The ANDROID_MUSIC client is what makes the cue ranges appear. The WEB_REMIX client returns only a plain-text description shelf for the same page.

Two POST requests when the player already knows the YouTube video ID:

```
POST https://music.youtube.com/youtubei/v1/next?prettyPrint=false&fields=contents
Content-Type: application/json

{"context":{"client":{"clientName":"WEB_REMIX","clientVersion":"1.20261110.04.00","hl":"en","gl":"US"}},"videoId":"<VIDEOID>"}
```

Find the lyrics tab:

```
contents.singleColumnMusicWatchNextResultsRenderer.tabbedRenderer
  .watchNextTabbedResultsRenderer.tabs[]
  .tabRenderer.endpoint.browseEndpoint
```

Use the endpoint whose `pageType` is `MUSIC_PAGE_TYPE_TRACK_LYRICS` (usually `browseId` starting with `MPLYt_`). Then:

```
POST https://music.youtube.com/youtubei/v1/browse?prettyPrint=false&fields=contents
Content-Type: application/json

{"context":{"client":{"clientName":"ANDROID_MUSIC","clientVersion":"7.27.52","hl":"en","gl":"US"}},"browseId":"MPLYt_..."}
```

The timed payload is:

```json
{
  "contents": {
    "elementRenderer": {
      "newElement": {
        "type": {
          "componentType": {
            "model": {
              "timedLyricsModel": {
                "lyricsData": {
                  "timedLyricsData": [
                    { "lyricLine": "Line", "cueRange": { "startTimeMilliseconds": "1234" } }
                  ]
                }
              }
            }
          }
        }
      }
    }
  }
}
```

`startTimeMilliseconds` is a **string**; convert it with `tonumber`. Without a video ID, the provider searches YouTube Music with the songs-only filter and resolves the top candidates (each via `next` + `browse`). It caps the whole lookup at six requests.

Notes:

- `fields=contents` is important: it reduces the response from ~650 KB to 10–25 KB.
- The Android client version matters. `7.27.52` works; `6.42.55` returns plain text and an unknown future version may 404. The provider retries once with `8.05.51`.
- No `429`/`403` was observed in local testing, but this is a private API with no published limits or stability guarantee. Disable it with `SPOTATUI_LYRICS_PROVIDERS=lrclib,netease,genius` if needed.
- YouTube Music depends on the exact entity. The official Get Lucky video has 77 timed lines without `cueRange`; its art track (`4D7u5KF7SP8`) has 109 lines with cue ranges.

## Genius

- Site: <https://genius.com>
- Auth: none for the public search/page used here. The official API requires a client token and does not return lyrics text through the API itself.
- Timestamps: **no**. The engine estimates a timeline from the plain text and labels it `text · estimated`.
- Request shape: spotatui's HTTP client sends `spotatui/<version>`, which Genius usually accepts. If it returns 403/429 or a Cloudflare challenge, the provider retries with a desktop browser UA through `http_post` + `X-HTTP-Method-Override: GET`. Disable with `SPOTATUI_LYRICS_GENIUS_POST=0`.

Search:

```
GET https://genius.com/api/search/multi?q=Guxo%20Si%20El%20Mundo%20Fuera%20Perfecto
```

The provider walks `response.sections[].hits[].result`, keeps `_type == "song"` (or URLs ending in `-lyrics`), and scores title/artist. It fetches the top one or two song pages.

Lyrics extraction:

- finds every `<div data-lyrics-container="true">`,
- balances nested `<div>` tags to find the closing tag,
- converts `<br>`/`</p>` to newlines, strips tags and decodes HTML entities,
- removes Genius artifacts (`You might also like`, `Embed`, `Read More`, contributor headers),
- joins the containers and drops duplicate/subset copies.

The parser is tested against a real Genius page in `tests/test_lrc.lua`/`tests/test_plugin.lua` fixtures; live pages can change, so the debug popup shows the exact URL if extraction fails.

## Selection rules

For each `(query, provider)` result:

```
total = 0.55 * title + 0.25 * artist + 0.20 * duration
```

If the query has no artist or the artist is a curator channel, the weights become `0.70 * title + 0.30 * duration`. Title and artist similarity are normalized (accents, punctuation, case), and a provider title's `Artist - Song` halves are compared separately.

The engine keeps:

- the best **synced** result (`total >= 0.68`),
- the best **plain** result (`total >= 0.68`),
- the best low-confidence result (`total >= 0.55`, shown with a warning).

A synced result is preferred when it is within 0.08 of the best plain result. A high-confidence synced result stops the race; a plain result of 0.85 or more stops it once all providers for that query have been tried. `m` cycles the metadata query variants; `r` resets to variant 1 and retries.

## Adding a provider

Create `ytlyrics/providers/yourprovider.lua`:

```lua
local M = { name = "Your Provider", id = "yourprovider" }

function M.search(query, ctx, done)
  local http = ctx.http
  local results, errors = {}, {}

  http.get_json("https://example.com/search?q=" .. http.urlencode(query.title), 524288, function(data, err)
    if err then
      errors[#errors + 1] = err
      done(results, errors)
      return
    end

    results[#results + 1] = {
      provider = M.name,
      provider_id = M.id,
      title = data.title,
      artist = data.artist,
      duration_ms = data.duration_ms,
      synced = true,
      lines = { { time_ms = 12000, text = "..." } },
      url = "https://example.com/song/1",
    }
    done(results, errors)
  end)
end

return M
```

Then:

1. Register it in `PROVIDERS` in `ytlyrics/engine.lua`.
2. Add the id to `KNOWN_PROVIDERS` in `ytlyrics/config.lua`.
3. Add fixtures and a test in `tests/test_providers.lua`.
4. Document its auth/rate/timestamp behavior here.

Guidelines:

- Call `ctx.is_cancelled()` before and after async work.
- Check `http.is_success(resp)` and `http.decode_json`.
- Keep request counts small; stop on the first good answer.
- Never throw out of `done`; return errors in the `errors` array.
- Do not persist lyrics or provider responses.

## Legal

Lyrics are copyrighted. Providers are third-party services with their own terms. This plugin only displays what a provider returns, does not bypass paywalls or authentication, and does not store lyrics on disk. If a provider changes its terms or blocks the plugin, disable it with `SPOTATUI_LYRICS_PROVIDERS` or remove its module.
