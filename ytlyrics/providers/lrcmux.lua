-- lrcmux provider: an open MIT aggregator (Deezer/KuGou/Musixmatch/
-- YouTube Music/LRCLIB) with word-level timing. Its LRCLIB-compatible
-- endpoint returns the same syncedLyrics schema, so the existing LRC parser
-- handles it.
--
-- Public instance: https://api.lrcmux.dev (60 req/min, self-hostable).

local util = require("ytlyrics.util")
local lrc = require("ytlyrics.lrc")

local M = { name = "lrcmux", id = "lrcmux" }

local COMPAT = "https://api.lrcmux.dev/compat/lrclib/api/get"
local NATIVE = "https://api.lrcmux.dev/get"
local MAX_BODY = 524288

local function result_from_compat(payload, query)
  if type(payload) ~= "table" then
    return nil
  end
  local title = util.str(payload.trackName)
  if title == "" then
    title = query.title
  end
  local artist = util.str(payload.artistName)
  if artist == "" then
    artist = query.artist or ""
  end
  local duration = tonumber(payload.duration) or 0

  if type(payload.syncedLyrics) == "string" and util.trim(payload.syncedLyrics) ~= "" then
    local parsed = lrc.parse(payload.syncedLyrics)
    if parsed.synced then
      return {
        provider = M.name,
        provider_id = M.id,
        title = title,
        artist = artist,
        album = util.str(payload.albumName),
        duration_ms = math.floor(duration * 1000 + 0.5),
        synced = true,
        lines = parsed.lines,
        url = "https://lrcmux.dev",
      }
    end
  end
  if type(payload.plainLyrics) == "string" and util.trim(payload.plainLyrics) ~= "" then
    return {
      provider = M.name,
      provider_id = M.id,
      title = title,
      artist = artist,
      album = util.str(payload.albumName),
      duration_ms = math.floor(duration * 1000 + 0.5),
      synced = false,
      plain_text = payload.plainLyrics,
      url = "https://lrcmux.dev",
    }
  end
  return nil
end

local function result_from_native(payload, query)
  if type(payload) ~= "table" or type(payload.lines) ~= "table" or #payload.lines == 0 then
    return nil
  end
  local track = type(payload.track) == "table" and payload.track or {}
  local lines, plain, cued = {}, {}, 0
  for _, item in ipairs(payload.lines) do
    local text = util.trim(util.str(item.text))
    local start = tonumber(item.start)
    if text ~= "" then
      if start then
        cued = cued + 1
        lines[#lines + 1] = { time_ms = math.max(0, math.floor(start)), text = text }
      else
        plain[#plain + 1] = text
      end
    end
  end
  local duration = tonumber(track.duration) or 0
  local common = {
    provider = M.name,
    provider_id = M.id,
    title = util.str(track.title, query.title),
    artist = util.str(track.artist, query.artist or ""),
    album = util.str(track.album),
    duration_ms = duration > 0 and math.floor(duration * 1000 + 0.5) or (query.duration_ms or 0),
    url = "https://lrcmux.dev",
  }
  if cued >= 2 and #lines >= 2 then
    common.synced = true
    common.lines = lines
    return common
  end
  local text = table.concat(plain, "\n")
  if text == "" then
    for _, line in ipairs(lines) do
      text = text .. (text == "" and "" or "\n") .. line.text
    end
  end
  if text == "" then
    return nil
  end
  common.synced = false
  common.plain_text = text
  return common
end

function M.search(query, ctx, done)
  local http = ctx.http
  local results, errors = {}, {}
  local finished = false
  local requests = 0

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
      ctx.debug[#ctx.debug + 1] = "lrcmux " .. line
    end
  end

  local function native_fallback()
    if not query.title or util.trim(query.title) == "" then
      finish()
      return
    end
    requests = requests + 1
    if requests > 2 then
      finish()
      return
    end
    local url = NATIVE .. "?artist=" .. util.urlencode(query.artist or "")
      .. "&title=" .. util.urlencode(query.title)
      .. "&duration=" .. tostring(math.floor((query.duration_ms or 0) / 1000 + 0.5))
      .. "&format=json"
    debug("native: " .. url)
    http.get(url, function(resp, err)
      if cancelled() then
        finish()
        return
      end
      if err then
        errors[#errors + 1] = "lrcmux transport: " .. tostring(err)
        finish()
        return
      end
      if resp.status == 404 then
        finish()
        return
      end
      if not http.is_success(resp) then
        errors[#errors + 1] = "lrcmux HTTP " .. tostring(resp.status)
        finish()
        return
      end
      local payload, decode_err = http.decode_json(resp, MAX_BODY)
      if not payload then
        errors[#errors + 1] = "lrcmux " .. tostring(decode_err)
        finish()
        return
      end
      local result = result_from_native(payload, query)
      if result then
        results[#results + 1] = result
      end
      finish()
    end)
  end

  local artist = util.trim(query.artist or "")
  if artist ~= "" and query.title and util.trim(query.title) ~= "" then
    requests = requests + 1
    local url = COMPAT .. "?track_name=" .. util.urlencode(query.title)
      .. "&artist_name=" .. util.urlencode(artist)
      .. "&duration=" .. tostring(math.floor((query.duration_ms or 0) / 1000 + 0.5))
    debug("compat: " .. url)
    http.get(url, function(resp, err)
      if cancelled() then
        finish()
        return
      end
      if err then
        errors[#errors + 1] = "lrcmux transport: " .. tostring(err)
        native_fallback()
        return
      end
      if resp.status == 404 then
        native_fallback()
        return
      end
      if not http.is_success(resp) then
        errors[#errors + 1] = "lrcmux HTTP " .. tostring(resp.status)
        native_fallback()
        return
      end
      local payload, decode_err = http.decode_json(resp, MAX_BODY)
      if not payload then
        errors[#errors + 1] = "lrcmux " .. tostring(decode_err)
        native_fallback()
        return
      end
      local result = result_from_compat(payload, query)
      if result then
        results[#results + 1] = result
        finish()
      else
        native_fallback()
      end
    end)
  else
    native_fallback()
  end
end

M._result_from_compat = result_from_compat
M._result_from_native = result_from_native

return M
