#!/usr/bin/env bash
# Live provider smoke test. Not part of CI: providers can block or change.
# Requires curl and jq. Prints only status, never lyric text.

set -euo pipefail

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS $name"
    pass=$((pass + 1))
  else
    echo "FAIL $name" >&2
    fail=$((fail + 1))
  fi
}

echo "== LRCLIB =="
curl -fsS -G "https://lrclib.net/api/get" \
  --data-urlencode "track_name=Get Lucky" \
  --data-urlencode "artist_name=Daft Punk" \
  --data-urlencode "duration=249" \
  -H "User-Agent: spotatui-lyrics-smoke/0.1.0" \
  -o "$tmp/lrclib.json"
check "LRCLIB exact lookup has synced lyrics" \
  jq -e '.syncedLyrics != null and (.syncedLyrics | length > 0)' "$tmp/lrclib.json"

echo "== NetEase =="
curl -fsS -X POST "https://music.163.com/api/cloudsearch/pc" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Referer: https://music.163.com/" \
  --data-urlencode "s=Bad Bunny Tití Me Preguntó" \
  --data-urlencode "type=1" \
  --data-urlencode "limit=3" \
  --data-urlencode "offset=0" \
  -o "$tmp/netease-search.json"
check "NetEase search returns a song" \
  jq -e '.result.songs[0].id != null' "$tmp/netease-search.json"

song_id="$(jq -r '.result.songs[0].id' "$tmp/netease-search.json")"
curl -fsS "https://music.163.com/api/song/lyric?id=${song_id}&lv=1&kv=1&tv=-1" \
  -H "Referer: https://music.163.com/" \
  -o "$tmp/netease-lyric.json"
check "NetEase lyric endpoint returns LRC" \
  jq -e '(.lrc.lyric // "") | length > 0' "$tmp/netease-lyric.json"

echo "== Genius =="
curl -fsS -G "https://genius.com/api/search/multi" \
  --data-urlencode "q=Guxo Si El Mundo Fuera Perfecto" \
  -H "User-Agent: spotatui/0.48.0" \
  -o "$tmp/genius-search.json"
check "Genius search returns sections" \
  jq -e '.response.sections | length > 0' "$tmp/genius-search.json"

curl -fsSL "https://genius.com/Guxo-si-el-mundo-fuera-perfecto-lyrics" \
  -H "User-Agent: spotatui/0.48.0" \
  -o "$tmp/genius-page.html"
check "Genius page has a lyrics container" \
  grep -q 'data-lyrics-container="true"' "$tmp/genius-page.html"

echo "== YouTube Music =="
yt_ctx='{"client":{"clientName":"WEB_REMIX","clientVersion":"1.20261110.04.00","hl":"en","gl":"US"}}'
curl -fsS -X POST "https://music.youtube.com/youtubei/v1/next?prettyPrint=false&fields=contents" \
  -H "Content-Type: application/json" \
  --data "{\"context\":${yt_ctx},\"videoId\":\"4D7u5KF7SP8\"}" \
  -o "$tmp/ytmusic-next.json"
check "YouTube Music next returns a lyrics tab" \
  jq -e '[.. | objects | select(has("browseEndpoint")) | .browseEndpoint.browseId | select(startswith("MPLYt_"))] | length > 0' "$tmp/ytmusic-next.json"

yt_browse_id="$(jq -r '[.. | objects | select(has("browseEndpoint")) | .browseEndpoint.browseId | select(startswith("MPLYt_"))] | first' "$tmp/ytmusic-next.json")"
yt_app_ctx='{"client":{"clientName":"ANDROID_MUSIC","clientVersion":"7.27.52","hl":"en","gl":"US"}}'
curl -fsS -X POST "https://music.youtube.com/youtubei/v1/browse?prettyPrint=false&fields=contents" \
  -H "Content-Type: application/json" \
  --data "{\"context\":${yt_app_ctx},\"browseId\":\"${yt_browse_id}\"}" \
  -o "$tmp/ytmusic-browse.json"
check "YouTube Music Android browse has cue ranges" \
  jq -e '.contents.elementRenderer.newElement.type.componentType.model.timedLyricsModel.lyricsData.timedLyricsData | length > 10' "$tmp/ytmusic-browse.json"

echo
echo "${pass} passed, ${fail} failed"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
