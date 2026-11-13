-- Genius provider: broad catalogue, plain text only.
--
-- Genius does not expose timestamps. The engine estimates a timeline from the
-- text so the screen still follows playback, and labels it as estimated.
--
-- Genius rejects requests without a browser-like UA. spotatui's own HTTP client
-- sends "spotatui/<version>", which is usually accepted. When it is not, the
-- plugin retries through http_post with X-HTTP-Method-Override: GET and a
-- desktop browser UA. That fallback is opt-out with
-- SPOTATUI_LYRICS_GENIUS_POST=0.

local util = require("ytlyrics.util")
local score = require("ytlyrics.score")

local M = { name = "Genius", id = "genius" }

local SEARCH_URL = "https://genius.com/api/search/multi"
local MAX_SEARCH_BODY = 524288
local MAX_PAGE_BODY = 4194304

local function browser_headers(accept)
  return {
    ["User-Agent"] = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " ..
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    ["Accept"] = accept or "text/html,application/xhtml+xml",
    ["Accept-Language"] = "en-US,en;q=0.9,es;q=0.8",
  }
end

local function looks_blocked(resp)
  if not resp then
    return true
  end
  if resp.status == 403 or resp.status == 429 then
    return true
  end
  if resp.body:find("Just a moment", 1, true) or resp.body:find("cf-challenge", 1, true) then
    return true
  end
  return false
end

--- GET with a one-shot fallback to the POST/override trick.
local function get_with_fallback(url, ctx, accept, max_body, callback)
  local http = ctx.http
  local function retry()
    if ctx.config and ctx.config.genius_browser_fallback == false then
      callback(nil, "Genius blocked the request")
      return
    end
    if ctx.debug then
      ctx.debug[#ctx.debug + 1] = "Genius retry with browser UA: " .. url
    end
    http.get_override(url, browser_headers(accept), function(resp, err)
      if err then
        callback(nil, tostring(err))
        return
      end
      callback(resp, nil)
    end)
  end

  http.get(url, function(resp, err)
    if err then
      retry()
      return
    end
    if looks_blocked(resp) then
      retry()
      return
    end
    if max_body and #resp.body > max_body then
      callback(nil, "Genius response too large")
      return
    end
    callback(resp, nil)
  end)
end

local function artist_from_result(result)
  if type(result.primary_artist) == "table" then
    local name = util.str(result.primary_artist.name)
    if name ~= "" then
      return name
    end
  end
  local full = util.str(result.full_title)
  local artist = full:match(" by (.+)$")
  if artist then
    return util.trim(artist)
  end
  return util.str(result.artist_names)
end

local function map_song(result)
  local url = util.str(result.url)
  if url:sub(1, 1) == "/" then
    url = "https://genius.com" .. url
  end
  return {
    id = result.id,
    title = util.str(result.title),
    artist = artist_from_result(result),
    duration_ms = 0,
    url = url,
    full_title = util.str(result.full_title),
  }
end

local function extract_containers(page)
  local containers = {}
  local search_from = 1
  while true do
    local attr = page:find('data-lyrics-container="true"', search_from, true)
    if not attr then
      break
    end
    local start = nil
    for i = attr, math.max(1, attr - 600), -1 do
      if page:sub(i, i + 3) == "<div" then
        start = i
        break
      end
    end
    if start then
      local j = start
      local depth = 0
      local finish = nil
      while j <= #page do
        local open_at = page:find("<div", j, true)
        local close_at = page:find("</div>", j, true)
        if not open_at and not close_at then
          break
        end
        if open_at and (not close_at or open_at < close_at) then
          depth = depth + 1
          j = open_at + 4
        else
          depth = depth - 1
          j = close_at + 6
          if depth == 0 then
            finish = close_at + 5
            break
          end
        end
      end
      if finish then
        local tag_end = page:find(">", start, true)
        if tag_end and tag_end < finish then
          containers[#containers + 1] = page:sub(tag_end + 1, finish - 6)
        end
        search_from = finish + 1
      else
        search_from = attr + 1
      end
    else
      search_from = attr + 1
    end
  end
  return containers
end

local function html_to_text(html)
  local text = html
  text = text:gsub("<br%s*/>", "\n")
  text = text:gsub("<br%s*>", "\n")
  text = text:gsub("</p%s*>", "\n")
  text = text:gsub("<p[^>]*>", "")
  text = text:gsub("<script[^>]*>.-</script>", "")
  text = text:gsub("<style[^>]*>.-</style>", "")
  text = text:gsub("<[^>]+>", "")
  text = util.html_unescape(text)
  return text
end

local function cleanup_lyrics(text)
  local lines = {}
  for _, raw in ipairs(util.split(text, "\n")) do
    local line = util.trim(raw)
    local n = util.normalize(line)
    if line ~= ""
      and n ~= "you might also like"
      and n ~= "embed"
      and n ~= "read more"
      and not line:match("^%d+ Contributors") then
      lines[#lines + 1] = line
    end
  end

  -- Genius puts the page header ("12 ContributorsSong Lyrics") before the
  -- first section marker inside the first container. Drop that prefix when a
  -- section marker exists.
  local first_marker = nil
  for i, line in ipairs(lines) do
    if line:match("^%[.*%]$") then
      first_marker = i
      break
    end
  end
  if first_marker and first_marker <= 3 then
    local trimmed = {}
    for i = first_marker, #lines do
      trimmed[#trimmed + 1] = lines[i]
    end
    lines = trimmed
  end

  return table.concat(lines, "\n")
end

local function extract_lyrics(page)
  local containers = extract_containers(page)
  local chunks, seen = {}, {}
  for _, html in ipairs(containers) do
    local text = cleanup_lyrics(html_to_text(html))
    if text ~= "" and not seen[text] then
      -- Genius sometimes renders the same lyrics twice (one visible, one
      -- hidden). Keep the longer copy when one chunk contains the other.
      local contained = false
      for i, existing in ipairs(chunks) do
        if existing:find(text, 1, true) then
          contained = true
          break
        elseif text:find(existing, 1, true) then
          chunks[i] = text
          seen[text] = true
          contained = true
          break
        end
      end
      if not contained then
        seen[text] = true
        chunks[#chunks + 1] = text
      end
    end
  end
  return table.concat(chunks, "\n")
end

M.extract_lyrics = extract_lyrics

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

  local function fetch_page(song, index, candidates)
    if cancelled() then
      finish()
      return
    end
    if requests >= 4 or not song.url or song.url == "" then
      finish()
      return
    end
    requests = requests + 1
    if ctx.debug then
      ctx.debug[#ctx.debug + 1] = "Genius page: " .. song.url
    end
    get_with_fallback(song.url, ctx, "text/html,application/xhtml+xml", MAX_PAGE_BODY, function(resp, err)
      if cancelled() then
        finish()
        return
      end
      if err then
        errors[#errors + 1] = "Genius page: " .. tostring(err)
      elseif http.is_success(resp) then
        local ok, text = pcall(extract_lyrics, resp.body)
        if ok and type(text) == "string" and text ~= "" then
          results[#results + 1] = {
            provider = M.name,
            provider_id = M.id,
            title = song.title,
            artist = song.artist,
            album = "",
            duration_ms = song.duration_ms or 0,
            synced = false,
            plain_text = text,
            url = song.url,
          }
        else
          errors[#errors + 1] = "Genius page had no lyrics container"
        end
      else
        errors[#errors + 1] = "Genius page HTTP " .. tostring(resp.status)
      end

      if #results == 0 and index < 2 and candidates[index + 1] then
        fetch_page(candidates[index + 1], index + 1, candidates)
      else
        finish()
      end
    end)
  end

  local function handle_search(payload)
    local sections = type(payload) == "table" and payload.response and payload.response.sections
    if type(sections) ~= "table" then
      finish()
      return
    end
    local mapped, seen = {}, {}
    for _, section in ipairs(sections) do
      if type(section) == "table" and type(section.hits) == "table" then
        for _, hit in ipairs(section.hits) do
          local result = type(hit) == "table" and hit.result or nil
          if type(result) == "table" and (result._type == "song" or result.url and tostring(result.url):find("%-lyrics$")) then
            local song = map_song(result)
            if song.title ~= "" and song.url ~= "" and not seen[song.url] then
              seen[song.url] = true
              mapped[#mapped + 1] = song
            end
          end
        end
      end
    end
    if #mapped == 0 then
      finish()
      return
    end
    score.rank(mapped, query, {})
    fetch_page(mapped[1], 1, mapped)
  end

  local url = SEARCH_URL .. "?q=" .. util.urlencode(
    query.artist and util.trim(query.artist) ~= ""
      and (query.title .. " " .. query.artist)
      or query.title
  )
  requests = requests + 1
  if ctx.debug then
    ctx.debug[#ctx.debug + 1] = "Genius search: " .. url
  end
  get_with_fallback(url, ctx, "application/json", MAX_SEARCH_BODY, function(resp, err)
    if cancelled() then
      finish()
      return
    end
    if err then
      errors[#errors + 1] = "Genius search: " .. tostring(err)
      finish()
      return
    end
    if not http.is_success(resp) then
      errors[#errors + 1] = "Genius search HTTP " .. tostring(resp.status)
      finish()
      return
    end
    local decoded, decode_err = http.decode_json(resp, MAX_SEARCH_BODY)
    if not decoded then
      errors[#errors + 1] = "Genius " .. tostring(decode_err)
      finish()
      return
    end
    handle_search(decoded)
  end)
end

return M
