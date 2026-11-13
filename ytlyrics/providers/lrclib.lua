-- LRCLIB provider: free, no account, real LRC timestamps.
-- https://lrclib.net/docs

local util = require("ytlyrics.util")
local lrc = require("ytlyrics.lrc")

local M = { name = "LRCLIB", id = "lrclib" }

local API = "https://lrclib.net/api"

local function has_text(value)
  return type(value) == "string" and util.trim(value) ~= ""
end

local function result_from_record(record, extra)
  if type(record) ~= "table" then
    return nil
  end
  if record.instrumental == true and not has_text(record.syncedLyrics) and not has_text(record.plainLyrics) then
    return nil
  end

  local title = util.str(record.trackName)
  if title == "" then
    title = util.str(record.name)
  end
  if title == "" then
    return nil
  end

  local duration = tonumber(record.duration) or 0
  local parsed = nil
  if has_text(record.syncedLyrics) then
    parsed = lrc.parse(record.syncedLyrics)
  end
  if parsed and parsed.synced then
    return {
      provider = M.name,
      provider_id = M.id,
      title = title,
      artist = util.str(record.artistName),
      album = util.str(record.albumName),
      duration_ms = math.floor(duration * 1000 + 0.5),
      synced = true,
      lines = parsed.lines,
      url = record.id and ("https://lrclib.net/api/get/" .. tostring(record.id)) or nil,
      raw = extra,
    }
  end
  if has_text(record.plainLyrics) then
    return {
      provider = M.name,
      provider_id = M.id,
      title = title,
      artist = util.str(record.artistName),
      album = util.str(record.albumName),
      duration_ms = math.floor(duration * 1000 + 0.5),
      synced = false,
      plain_text = record.plainLyrics,
      url = record.id and ("https://lrclib.net/api/get/" .. tostring(record.id)) or nil,
      raw = extra,
    }
  end
  return nil
end

local function collect_records(payload, out, extra)
  if type(payload) ~= "table" then
    return
  end
  -- /api/search returns an array; /api/get returns one object.
  if payload[1] ~= nil then
    for _, record in ipairs(payload) do
      local result = result_from_record(record, extra)
      if result then
        out[#out + 1] = result
      end
    end
  else
    local result = result_from_record(payload, extra)
    if result then
      out[#out + 1] = result
    end
  end
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

  local function request(url, label, on_payload)
    if cancelled() then
      finish()
      return
    end
    if requests >= 3 then
      finish()
      return
    end
    requests = requests + 1
    if ctx.debug then
      ctx.debug[#ctx.debug + 1] = "LRCLIB " .. label .. ": " .. url
    end
    http.get(url, function(resp, err)
      if cancelled() then
        finish()
        return
      end
      if err then
        errors[#errors + 1] = "LRCLIB transport: " .. tostring(err)
        on_payload(nil)
        return
      end
      if resp.status == 404 then
        on_payload(nil)
        return
      end
      if resp.status == 429 then
        errors[#errors + 1] = "LRCLIB rate limited"
        finish()
        return
      end
      if not http.is_success(resp) then
        errors[#errors + 1] = "LRCLIB HTTP " .. tostring(resp.status)
        on_payload(nil)
        return
      end
      local decoded, decode_err = http.decode_json(resp, max_body)
      if not decoded then
        errors[#errors + 1] = "LRCLIB " .. tostring(decode_err)
        on_payload(nil)
        return
      end
      on_payload(decoded)
    end)
  end

  local function search_fallback()
    if query.artist and util.trim(query.artist) ~= "" then
      local url = API .. "/search?track_name=" .. util.urlencode(query.title)
        .. "&artist_name=" .. util.urlencode(query.artist)
      request(url, "fuzzy search", function(payload)
        collect_records(payload, results, "search")
        if #results > 0 then
          finish()
          return
        end
        -- Last resort: a free-text query can still find the song when the
        -- artist credit is wrong.
        local q = query.artist ~= "" and (query.title .. " " .. query.artist) or query.title
        request(API .. "/search?q=" .. util.urlencode(q), "free-text search", function(free_payload)
          collect_records(free_payload, results, "q")
          finish()
        end)
      end)
    else
      local q = query.title
      request(API .. "/search?q=" .. util.urlencode(q), "title search", function(payload)
        collect_records(payload, results, "q")
        finish()
      end)
    end
  end

  if query.artist and util.trim(query.artist) ~= "" and (query.duration_ms or 0) > 0 then
    local seconds = math.floor((query.duration_ms / 1000) + 0.5)
    local url = API .. "/get?track_name=" .. util.urlencode(query.title)
      .. "&artist_name=" .. util.urlencode(query.artist)
      .. "&duration=" .. tostring(seconds)
    request(url, "exact lookup", function(payload)
      collect_records(payload, results, "get")
      -- A plain-only exact hit is useful, but a fuzzy search can still find
      -- the synced version. Keep going until we have timestamps.
      local has_synced = false
      for _, result in ipairs(results) do
        if result.synced then
          has_synced = true
          break
        end
      end
      if has_synced then
        finish()
      else
        search_fallback()
      end
    end)
  else
    search_fallback()
  end
end

return M
