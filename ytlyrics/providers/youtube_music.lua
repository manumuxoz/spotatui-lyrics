-- YouTube Music provider (InnerTube, no account, no cookies).
--
-- Two API calls per song when the track already knows its videoId:
--   1. POST /youtubei/v1/next            client WEB_REMIX       -> lyrics browseId (MPLYt_...)
--   2. POST /youtubei/v1/browse          client ANDROID_MUSIC   -> timedLyricsModel
--
-- The ANDROID_MUSIC client is what makes timestamps appear. WEB_REMIX only
-- returns a plain-text description shelf for the same browseId.
--
-- No API key, cookie, visitorData or poToken is needed (verified 2026-11-15).
-- `fields=contents` keeps the lyrics payload at ~10-25 KB instead of ~650 KB.
--
-- Without a videoId one extra /search call is needed (songs-only filter); the
-- first few hits are then resolved through next+browse until one has lyrics.

local util = require("ytlyrics.util")
local score = require("ytlyrics.score")

local M = { name = "YouTube Music", id = "ytmusic" }

local API = "https://music.youtube.com/youtubei/v1/"
local CLIENT_WEB = { name = "WEB_REMIX", version = "1.20261110.04.00" }
local CLIENT_APP = { name = "ANDROID_MUSIC", version = "7.27.52" }
local CLIENT_APP_ALT = { name = "ANDROID_MUSIC", version = "8.05.51" }

local HL = "en"
local GL = "US"

-- Songs-only search filter ("Songs" chip). Keeps live/reaction uploads out.
local SONGS_PARAMS = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
local TAIL = "?prettyPrint=false&fields=contents"
local JSON_HEADERS = { ["Content-Type"] = "application/json" }
local MAX_BODY = 524288
local MAX_REQUESTS = 7

local function quote(value)
  value = tostring(value or "")
  return '"' .. value:gsub('[%c"\\]', function(c)
    if c == '"' then
      return '\\"'
    elseif c == "\\" then
      return "\\\\"
    end
    return string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function context_json(client)
  return '{"client":{"clientName":' .. quote(client.name)
    .. ',"clientVersion":' .. quote(client.version)
    .. ',"hl":' .. quote(HL) .. ',"gl":' .. quote(GL) .. "}}"
end

local function at(node, ...)
  local cur = node
  for i = 1, select("#", ...) do
    if type(cur) ~= "table" then
      return nil
    end
    cur = cur[select(i, ...)]
  end
  return cur
end

--- Locate the "MPLYt_..." lyrics page id inside a /next response.
local function find_lyrics_id(payload)
  local tabs = at(payload, "contents", "singleColumnMusicWatchNextResultsRenderer",
    "tabbedRenderer", "watchNextTabbedResultsRenderer", "tabs")
  if type(tabs) ~= "table" then
    return nil
  end
  for _, tab in ipairs(tabs) do
    local endpoint = at(tab, "tabRenderer", "endpoint", "browseEndpoint")
    local id = endpoint and endpoint.browseId
    if type(id) == "string" and id ~= "" then
      local page_type = at(endpoint, "browseEndpointContextSupportedConfigs",
        "browseEndpointContextMusicConfig", "pageType")
      if page_type == "MUSIC_PAGE_TYPE_TRACK_LYRICS" or id:sub(1, 6) == "MPLYt_" then
        return id
      end
    end
  end
  return nil
end

--- Turn timedLyricsData into LRC-style lines.
-- Items look like {"lyricLine":"...","cueRange":{"startTimeMilliseconds":"1234"}}.
-- Timestamps are JSON strings, and some tracks ship the model with no cueRange
-- at all: that case degrades to plain text.
local function lines_from_timed(tld)
  if type(tld) ~= "table" or #tld == 0 then
    return nil
  end
  local plain, cued = {}, 0
  for _, item in ipairs(tld) do
    local text = util.trim(util.str(item.lyricLine))
    local start = tonumber(at(item, "cueRange", "startTimeMilliseconds"))
    plain[#plain + 1] = text
    if start then
      cued = cued + 1
      item._start = start
    end
  end

  if cued < 2 then
    local text = table.concat(plain, "\n"):gsub("\n\n+", "\n")
    return nil, util.trim(text)
  end

  local lines, last = {}, 0
  for _, item in ipairs(tld) do
    local text = util.trim(util.str(item.lyricLine))
    local start = item._start
    if not start then
      -- A cue-less line between timed ones: keep it at the previous timestamp.
      start = last
    end
    last = start
    if text ~= "" then
      lines[#lines + 1] = { time_ms = start, text = text }
    end
  end
  if #lines < 2 then
    return nil, util.trim(table.concat(plain, "\n"))
  end
  return lines, nil
end

--- Extract lyrics from a /browse response (either client shape).
local function lyrics_from_browse(payload)
  local model = at(payload, "contents", "elementRenderer", "newElement",
    "type", "componentType", "model")
  if type(model) == "table" then
    local timed = at(model, "timedLyricsModel", "lyricsData")
    if type(timed) == "table" then
      local lines, plain = lines_from_timed(timed.timedLyricsData)
      if lines then
        return { synced = true, lines = lines, source = util.str(timed.sourceMessage) }
      end
      if plain and plain ~= "" then
        return { synced = false, plain_text = plain, source = util.str(timed.sourceMessage) }
      end
    end
    local message = at(model, "musicMessageModel", "text")
    if type(message) == "string" and message ~= "" then
      return nil, message
    end
  end

  -- WEB_REMIX fallback shape: plain text in a description shelf.
  local shelf = at(payload, "contents", "sectionListRenderer", "contents", 1,
    "musicDescriptionShelfRenderer")
  if type(shelf) == "table" then
    local text = ""
    for _, run in ipairs(at(shelf, "description", "runs") or {}) do
      text = text .. util.str(run.text)
    end
    text = util.trim(text)
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    if text ~= "" then
      return { synced = false, plain_text = text, source = "shelf" }
    end
  end
  return nil, "no lyrics in response"
end

--- Recursively collect musicResponsiveListItemRenderer hits from /search.
local function collect_search(node, out)
  if type(node) ~= "table" then
    return
  end
  if type(node.musicResponsiveListItemRenderer) == "table" then
    local item = node.musicResponsiveListItemRenderer
    local video_id = at(item, "playlistItemData", "videoId")
    local title = util.str(at(item, "flexColumns", 1, "musicResponsiveListItemFlexColumnRenderer",
      "text", "runs", 1, "text"))
    if type(video_id) == "string" and video_id ~= "" and title ~= "" then
      local artist = util.str(at(item, "flexColumns", 2, "musicResponsiveListItemFlexColumnRenderer",
        "text", "runs", 1, "text"))
      local length = util.str(at(item, "fixedColumns", 1, "musicResponsiveListItemFixedColumnRenderer",
        "text", "runs", 1, "text"))
      local duration_ms = 0
      local m, s = length:match("^(%d+):(%d+)$")
      if m then
        duration_ms = (tonumber(m) * 60 + tonumber(s)) * 1000
      end
      out[#out + 1] = {
        video_id = video_id,
        title = title,
        artist = artist,
        album = "",
        duration_ms = duration_ms,
      }
    end
    return
  end
  for _, value in pairs(node) do
    if type(value) == "table" then
      collect_search(value, out)
    end
  end
end

-- Albums ship several ATV rows for one song ("Radio Edit", "Remix", "Live").
-- The plugin's score treats them as equal, so break the tie towards the plain
-- title before spending a lyrics request on it.
local VERSION_MARKERS = {
  "remix", "live", "edit", "version", "instrumental", "karaoke", "cover",
  "acoustic", "demo", "reprise", "extended", "remaster", "sped up", "slowed",
  "nightcore", "8d",
}

local function version_penalty(title, query_title)
  local t = util.normalize(title)
  local q = util.normalize(query_title or "")
  for _, word in ipairs(VERSION_MARKERS) do
    if t:find(word, 1, true) and not q:find(word, 1, true) then
      return 1
    end
  end
  return 0
end

function M.search(query, ctx, done)
  local http = ctx.http
  local results, errors = {}, {}
  local requests, finished = 0, false

  local function finish()
    if finished then
      return
    end
    finished = true
    done(results, errors)
  end

  local function cancelled()
    return ctx.is_cancelled and ctx.is_cancelled() or false
  end

  local function debug(line)
    if ctx.debug then
      ctx.debug[#ctx.debug + 1] = "YouTube Music " .. line
    end
  end

  local function post(ep, body, label, callback)
    if cancelled() then
      finish()
      return
    end
    if requests >= MAX_REQUESTS then
      finish()
      return
    end
    requests = requests + 1
    debug(label .. ": " .. ep)
    http.post_json(API .. ep .. TAIL, body, JSON_HEADERS, MAX_BODY, function(payload, err, resp)
      if cancelled() then
        finish()
        return
      end
      if err then
        errors[#errors + 1] = "YouTube Music " .. label .. ": " .. tostring(err)
        callback(nil, nil)
        return
      end
      callback(payload, resp)
    end)
  end

  -- Step 2: browse the lyrics page with the client that returns cue ranges.
  local function browse_lyrics(browse_id, client, meta, on_done)
    local body = '{"context":' .. context_json(client) .. ',"browseId":' .. quote(browse_id) .. "}"
    post("browse", body, "browse " .. client.name, function(payload, resp)
      local parsed, message = nil, "no response"
      if payload then
        parsed, message = lyrics_from_browse(payload)
      elseif resp and resp.status == 404 and client == CLIENT_APP then
        -- The server rejects unknown client versions with 404; retry once.
        browse_lyrics(browse_id, CLIENT_APP_ALT, meta, on_done)
        return
      end
      if parsed then
        results[#results + 1] = {
          provider = M.name,
          provider_id = M.id,
          title = meta.title,
          artist = meta.artist,
          album = meta.album or "",
          duration_ms = meta.duration_ms or 0,
          synced = parsed.synced,
          lines = parsed.lines,
          plain_text = parsed.plain_text,
          url = meta.video_id and ("https://music.youtube.com/watch?v=" .. meta.video_id) or nil,
          raw = { browse_id = browse_id, source = parsed.source },
        }
      else
        errors[#errors + 1] = "YouTube Music " .. tostring(message)
      end
      on_done(parsed)
    end)
  end

  -- Step 1: /next resolves videoId -> lyrics browseId.
  local function resolve_video(meta, on_done)
    local body = '{"context":' .. context_json(CLIENT_WEB) .. ',"videoId":' .. quote(meta.video_id) .. "}"
    post("next", body, "next " .. tostring(meta.video_id), function(payload)
      local browse_id = payload and find_lyrics_id(payload)
      if not browse_id then
        errors[#errors + 1] = "YouTube Music has no lyrics page for " .. tostring(meta.video_id)
        on_done(nil)
        return
      end
      browse_lyrics(browse_id, CLIENT_APP, meta, on_done)
    end)
  end

  --- Resolve candidates until one has cue ranges. Plain results are kept in
  --- `results`; if none is synced, on_finished lets the caller finish with the
  --- plain fallback.
  local function resolve_all(candidates, index, on_finished)
    if cancelled() or index > #candidates then
      on_finished()
      return
    end
    resolve_video(candidates[index], function(parsed)
      if parsed and parsed.synced then
        finish()
        return
      end
      resolve_all(candidates, index + 1, on_finished)
    end)
  end

  local function search_candidates(query, callback)
    local text = util.trim(query.title)
    if query.artist and util.trim(query.artist) ~= "" then
      text = text .. " " .. util.trim(query.artist)
    end
    local body = '{"context":' .. context_json(CLIENT_WEB) .. ',"query":' .. quote(text)
      .. ',"params":"' .. SONGS_PARAMS .. '"}'
    post("search", body, "search", function(payload)
      local candidates = {}
      collect_search(payload, candidates)
      if #candidates == 0 then
        errors[#errors + 1] = "YouTube Music search returned nothing"
        callback({})
        return
      end
      score.rank(candidates, query, {})
      table.sort(candidates, function(a, b)
        if a.effective ~= b.effective then
          return a.effective > b.effective
        end
        local pa, pb = version_penalty(a.title, query.title), version_penalty(b.title, query.title)
        if pa ~= pb then
          return pa < pb
        end
        return #a.title < #b.title
      end)
      callback(candidates)
    end)
  end

  -- Fast path: the player already knows the videoId.
  local direct = util.str(query.video_id)
  if direct ~= "" then
    resolve_video({
      video_id = direct,
      title = query.title,
      artist = query.artist,
      album = "",
      duration_ms = query.duration_ms or 0,
    }, function(parsed)
      if parsed and parsed.synced then
        finish()
        return
      end
      -- The exact video may only expose text. Search for an art track, which
      -- often carries cue ranges, before falling back to the text result.
      search_candidates(query, function(candidates)
        local filtered = {}
        for _, candidate in ipairs(candidates) do
          if candidate.video_id ~= direct then
            filtered[#filtered + 1] = candidate
          end
        end
        local top = {}
        for i = 1, math.min(2, #filtered) do
          top[i] = filtered[i]
        end
        if #top == 0 then
          finish()
          return
        end
        resolve_all(top, 1, function()
          finish()
        end)
      end)
    end)
    return
  end

  search_candidates(query, function(candidates)
    local top = {}
    for i = 1, math.min(3, #candidates) do
      top[i] = candidates[i]
    end
    if #top == 0 then
      finish()
      return
    end
    resolve_all(top, 1, function()
      finish()
    end)
  end)
end

M._find_lyrics_id = find_lyrics_id
M._collect_search = collect_search
M._lyrics_from_browse = lyrics_from_browse
M._lines_from_timed = lines_from_timed

return M
