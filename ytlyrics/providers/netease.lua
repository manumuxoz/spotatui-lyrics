-- NetEase Cloud Music provider.
--
-- The public web endpoints need no account and return line-synced LRC for a
-- large catalogue, including Latin music that LRCLIB often misses. They are
-- unofficial and can be unavailable in some regions; failures are non-fatal.

local util = require("ytlyrics.util")
local lrc = require("ytlyrics.lrc")
local score = require("ytlyrics.score")

local M = { name = "NetEase", id = "netease" }

local SEARCH_URL = "https://music.163.com/api/cloudsearch/pc"
local LYRIC_URL = "https://music.163.com/api/song/lyric"

local function artists_of(song)
  local names = {}
  local list = song.ar or song.artists
  if type(list) == "table" then
    for _, artist in ipairs(list) do
      local name = type(artist) == "table" and (artist.name or artist.nickname) or artist
      if type(name) == "string" and name ~= "" then
        names[#names + 1] = name
      end
    end
  end
  return table.concat(names, ", ")
end

local function duration_of(song)
  return tonumber(song.dt) or tonumber(song.duration) or 0
end

local function map_song(song)
  return {
    id = song.id,
    title = util.str(song.name),
    artist = artists_of(song),
    album = type(song.al) == "table" and util.str(song.al.name) or util.str(song.album),
    duration_ms = duration_of(song),
  }
end

local function parse_yrc(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  local lines = {}
  for raw in text:gmatch("[^\n]+") do
    local ok, decoded = pcall(spotatui.json_decode, raw)
    if ok and type(decoded) == "table" and type(decoded.t) == "number" and type(decoded.c) == "table" then
      local words = {}
      for _, chunk in ipairs(decoded.c) do
        if type(chunk) == "table" and type(chunk.tx) == "string" then
          words[#words + 1] = chunk.tx
        end
      end
      local line = util.trim(table.concat(words, ""))
      if line ~= "" then
        lines[#lines + 1] = { time_ms = decoded.t, text = line }
      end
    end
  end
  if #lines < 2 then
    return nil
  end
  return {
    lines = lines,
    synced = true,
    estimated = false,
  }
end

local function lyrics_from_payload(payload)
  if type(payload) ~= "table" then
    return nil
  end
  local lrc_text = type(payload.lrc) == "table" and util.str(payload.lrc.lyric) or ""
  if lrc_text ~= "" then
    local parsed = lrc.parse(lrc_text)
    if parsed.synced then
      return { lines = parsed.lines, synced = true, estimated = false }
    end
    if parsed.plain_text ~= "" then
      return { plain_text = parsed.plain_text, synced = false }
    end
  end

  local yrc_text = type(payload.yrc) == "table" and util.str(payload.yrc.lyric) or ""
  local yrc_parsed = parse_yrc(yrc_text)
  if yrc_parsed then
    return yrc_parsed
  end

  local klyric = type(payload.klyric) == "table" and util.str(payload.klyric.lyric) or ""
  if klyric ~= "" then
    local parsed = lrc.parse(klyric)
    if parsed.synced then
      return { lines = parsed.lines, synced = true, estimated = false }
    end
    if parsed.plain_text ~= "" then
      return { plain_text = parsed.plain_text, synced = false }
    end
  end

  return nil
end

function M.search(query, ctx, done)
  local http = ctx.http
  local max_body = ctx.max_body_bytes or 524288
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

  local function fetch_lyrics(song, index)
    if cancelled() then
      finish()
      return
    end
    if not song.id or requests >= 3 then
      finish()
      return
    end
    requests = requests + 1
    local url = LYRIC_URL .. "?id=" .. tostring(song.id) .. "&lv=1&kv=1&tv=-1"
    if ctx.debug then
      ctx.debug[#ctx.debug + 1] = "NetEase lyric: " .. url
    end
    http.get(url, function(resp, err)
      if cancelled() then
        finish()
        return
      end
      if err then
        errors[#errors + 1] = "NetEase transport: " .. tostring(err)
      elseif http.is_success(resp) then
        local decoded, decode_err = http.decode_json(resp, max_body)
        if decoded then
          local lyrics = lyrics_from_payload(decoded)
          if lyrics then
            results[#results + 1] = {
              provider = M.name,
              provider_id = M.id,
              title = song.title,
              artist = song.artist,
              album = song.album,
              duration_ms = song.duration_ms,
              synced = lyrics.synced == true,
              lines = lyrics.lines,
              plain_text = lyrics.plain_text,
              url = "https://music.163.com/song?id=" .. tostring(song.id),
            }
          end
        else
          errors[#errors + 1] = "NetEase " .. tostring(decode_err)
        end
      end

      if index < 2 and #results == 0 then
        -- Try the next best search hit only when the first one had no lyrics.
        local next_song = ctx._netease_songs and ctx._netease_songs[index + 1]
        if next_song then
          fetch_lyrics(next_song, index + 1)
        else
          finish()
        end
      else
        finish()
      end
    end)
  end

  local function handle_search(payload)
    if cancelled() then
      finish()
      return
    end
    local songs = type(payload) == "table" and payload.result and payload.result.songs
    if type(songs) ~= "table" or #songs == 0 then
      finish()
      return
    end
    local mapped = {}
    for _, song in ipairs(songs) do
      local item = map_song(song)
      if item.title ~= "" then
        mapped[#mapped + 1] = item
      end
    end
    score.rank(mapped, query, {})
    ctx._netease_songs = mapped
    if #mapped == 0 then
      finish()
      return
    end
    fetch_lyrics(mapped[1], 1)
  end

  local function search_form(term, on_payload)
    if cancelled() then
      finish()
      return
    end
    requests = requests + 1
    local body = "s=" .. util.urlencode(term) .. "&type=1&limit=8&offset=0"
    if ctx.debug then
      ctx.debug[#ctx.debug + 1] = "NetEase search: " .. term
    end
    http.post(SEARCH_URL, body, {
      ["Content-Type"] = "application/x-www-form-urlencoded",
      ["Referer"] = "https://music.163.com/",
    }, function(resp, err)
      if cancelled() then
        finish()
        return
      end
      if err then
        errors[#errors + 1] = "NetEase transport: " .. tostring(err)
        on_payload(nil)
        return
      end
      if not http.is_success(resp) then
        errors[#errors + 1] = "NetEase HTTP " .. tostring(resp.status)
        on_payload(nil)
        return
      end
      local decoded, decode_err = http.decode_json(resp, max_body)
      if not decoded then
        errors[#errors + 1] = "NetEase " .. tostring(decode_err)
        on_payload(nil)
        return
      end
      on_payload(decoded)
    end)
  end

  local term = query.title
  if query.artist and util.trim(query.artist) ~= "" then
    term = query.title .. " " .. query.artist
  end

  search_form(term, function(payload)
    local songs = type(payload) == "table" and payload.result and payload.result.songs
    if type(songs) == "table" and #songs > 0 then
      handle_search(payload)
      return
    end
    -- A title-only search is a useful second chance for translated titles and
    -- channels that are not the artist.
    if term ~= query.title then
      search_form(query.title, function(fallback)
        if fallback then
          handle_search(fallback)
        else
          finish()
        end
      end)
    else
      finish()
    end
  end)
end

return M
