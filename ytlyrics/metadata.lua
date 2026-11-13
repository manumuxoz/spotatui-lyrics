-- YouTube metadata repair.
--
-- spotatui hands plugins the raw video title and the channel name. For a
-- YouTube source those are not "title" and "artist": the title is a marketing
-- string ("Artist - Song (Official Video) ft. X") and the channel is often a
-- curator ("7clouds", "MrSuicideSheep"). LRCLIB and the other providers index
-- songs by clean title + performing artist, so this module turns the raw row
-- into a ranked list of queries.

local util = require("ytlyrics.util")

local M = {}

local NOISE_PREFIXES = {
  "official", "oficial", "lyric", "lyrics", "letra", "audio", "video",
  "visualizer", "visualiser", "music video", "mv", "m/v", "hd", "4k", "8k",
  "remaster", "remastered", "remasterizado", "live", "en vivo", "performance",
  "acoustic", "cover", "remix", "extended", "radio edit", "album version",
  "single version", "version", "demo", "instrumental", "karaoke",
  "dance practice", "color coded", "prod", "produced", "feat", "ft",
  "featuring", "explicit", "clean", "sped up", "nightcore", "slowed",
  "reverb", "8d", "bass boosted", "mashup", "medley", "tribute", "fan made",
  "fanmade", "full song", "full video", "audio only", "download", "free",
  "subtitulad", "traduccion", "traducción", "sub espanol", "sub español",
  "youtube", "topic", "hq", "high quality", "extendida", "extended version",
  "original mix", "club mix", "dub mix", "vocal mix", "edit",
}

local CURATOR_WORDS = {
  "lyrics", "lyric", "music", "songs", "song", "vibes", "nation", "clouds",
  "sheep", "guide", "radio", "playlist", "channel", "records", "label",
  "official", "tv", "media", "sound", "audio", "mix", "mixtape", "promotion",
  "promoter", "archives", "archive", "proximity", "indiemono", "trap",
  "chill", "select", "selects", "collective", "network", "group", "studio",
  "entertainment", "hits", "pop", "latin", "reggaeton", "urban", "beats",
  "nightcore", "slowed", "sped up", "8d", "bass boosted", "remix", "cover",
  "karaoke",
}

local EDGE_PHRASES = {
  "official music video", "official video", "official audio",
  "official lyric video", "official visualizer", "lyric video",
  "lyrics video", "music video", "visualizer", "audio only", "full song",
  "full video", "remastered", "remaster", "remasterizado", "audio oficial",
  "video oficial", "video lyric", "en vivo", "live performance",
  "performance video", "acoustic version", "radio edit", "extended mix",
  "extended version", "album version", "single version", "explicit",
  "clean version", "sped up", "nightcore", "slowed", "reverb", "8d audio",
  "bass boosted", "color coded lyrics", "han/rom/eng", "dance practice",
  "subtitulado", "subtitulada", "traduccion", "traducción", "letra",
  "sub espanol", "sub español", "full hd", "high quality", "hq",
  "original mix", "club mix",
}

-- Words that are noise only at the very end of a title. Removing "video" or
-- "audio" anywhere would eat songs such as "Video Killed the Radio Star".
local TRAILING_WORDS = {
  "official", "video", "audio", "lyrics", "lyric", "mv", "m/v", "hd",
  "4k", "8k", "youtube", "topic", "hq", "edit",
}

local function lower(s)
  return type(s) == "string" and s:lower() or ""
end

local function starts_with_any(text, prefixes)
  local n = util.normalize(text)
  for _, prefix in ipairs(prefixes) do
    local p = util.normalize(prefix)
    if p ~= "" and n:sub(1, #p) == p then
      return true
    end
  end
  return false
end

local function contains_any(text, words)
  local n = util.normalize(text)
  for _, word in ipairs(words) do
    local w = util.normalize(word)
    if w ~= "" and n:find(w, 1, true) then
      return true
    end
  end
  return false
end

--- Whole-word variant. Used for credit detection so "ft" does not match
--- inside "Daft Punk".
local function contains_word(text, words)
  local padded = " " .. util.normalize(text) .. " "
  for _, word in ipairs(words) do
    local w = util.normalize(word)
    if w ~= "" and padded:find(" " .. w .. " ", 1, true) then
      return true
    end
  end
  return false
end

local function add_unique(list, value)
  value = util.trim(value)
  if value == "" then
    return
  end
  local key = util.normalize(value)
  for _, existing in ipairs(list) do
    if util.normalize(existing) == key then
      return
    end
  end
  list[#list + 1] = value
end

local function is_noise_tag(content)
  local c = util.trim(content)
  if c == "" then
    return true
  end
  if c:match("^%d%d%d%d$") then
    return true
  end
  if starts_with_any(c, NOISE_PREFIXES) then
    return true
  end
  if contains_any(c, { "remaster", "remastered", "remasterizado" }) then
    return true
  end
  return false
end

local function split_names(value)
  local names = {}
  -- Keep the full credit: "Earth, Wind & Fire" must not become "Earth".
  add_unique(names, value)
  local expanded = value:gsub("%s+[Aa][Nn][Dd]%s+", ",")
  for part in expanded:gmatch("[^,&]+") do
    add_unique(names, part)
  end
  return names
end

--- Pull "feat. X & Y" / "ft. X" / "featuring X" out of a string.
local function extract_featured(text, featured)
  local function consume(segment)
    local names = segment
      :gsub("^[Ff][Ee][Aa][Tt]%.?%s+", "")
      :gsub("^[Ff][Tt]%.?%s+", "")
      :gsub("^[Ff][Ee][Aa][Tt][Uu][Rr][Ii][Nn][Gg]%s+", "")
    for _, name in ipairs(split_names(names)) do
      add_unique(featured, name)
    end
    return ""
  end

  text = text:gsub("(%f[%w][Ff][Ee][Aa][Tt]%.?%s+[^%(%[%]%)]+)", consume)
  text = text:gsub("(%f[%w][Ff][Tt]%.?%s+[^%(%[%]%)]+)", consume)
  text = text:gsub("(%f[%w][Ff][Ee][Aa][Tt][Uu][Rr][Ii][Nn][Gg]%s+[^%(%[%]%)]+)", consume)
  return text
end

local function extract_producer(text)
  text = text:gsub("(%f[%w][Pp][Rr][Oo][Dd]%.?%s+[Bb][Yy]%s+[^%(%[%]%)]+)", "")
  text = text:gsub("(%f[%w][Pp][Rr][Oo][Dd][Uu][Cc][Ee][Dd]%s+[Bb][Yy]%s+[^%(%[%]%)]+)", "")
  return text
end

local function strip_brackets(text, featured)
  local function replace(content)
    local c = util.trim(content)
    if c == "" then
      return ""
    end
    if is_noise_tag(c) then
      return ""
    end
    return nil -- keep the original match, e.g. "(I Can't Get No)"
  end

  text = text:gsub("%b()", replace)
  text = text:gsub("%b[]", replace)
  text = text:gsub("%b{}", replace)
  text = text:gsub("【(.-)】", replace)
  text = text:gsub("（(.-)）", replace)
  -- A feat/prod segment removed from inside brackets leaves "()".
  text = text:gsub("%(%)", ""):gsub("%[%]", ""):gsub("{}", "")
  return text
end

local function trim_separators(text)
  text = util.collapse_ws(text)
  text = text:gsub("^[%s%-–—|/%~,;:]+", "")
  text = text:gsub("[%s%-–—|/%~,;:]+$", "")
  text = util.collapse_ws(text)
  return util.trim(text)
end

--- Remove a phrase when it sits on a word boundary, repeatedly.
local function remove_phrase(text, phrase)
  local p = lower(phrase)
  if p == "" then
    return text
  end
  local search_from = 1
  while true do
    local n = lower(text)
    local a, b = n:find(p, search_from, true)
    if not a then
      break
    end
    local before = text:sub(1, a - 1)
    local after = text:sub(b + 1)
    local left_ok = before == "" or before:match("[%s%-–—|/%~,;:%(%[]$") ~= nil
    local right_ok = after == "" or after:match("^[%s%-–—|/%~,;:%)%]]") ~= nil
    if left_ok and right_ok then
      local candidate = trim_separators(before .. " " .. after)
      if candidate ~= "" then
        text = candidate
        search_from = 1
      else
        search_from = b + 1
      end
    else
      search_from = b + 1
    end
  end
  return text
end

local function strip_edge_phrases(text)
  for _, phrase in ipairs(EDGE_PHRASES) do
    text = remove_phrase(text, phrase)
  end
  -- "Artist - Song - Live" / "Song – Remix": version tags after a dash are
  -- safe to drop even though a standalone "Live" may be part of a title.
  local version_suffixes = {
    "extended mix", "radio edit", "instrumental", "acoustic", "karaoke",
    "nightcore", "sped up", "slowed", "remix", "live", "demo",
  }
  local changed = true
  while changed do
    changed = false
    for _, suffix in ipairs(version_suffixes) do
      local trimmed = util.trim(text)
      local lower_text = trimmed:lower()
      local lower_suffix = suffix:lower()
      if #lower_text >= #lower_suffix
        and lower_text:sub(-#lower_suffix) == lower_suffix then
        local before = util.trim(trimmed:sub(1, #trimmed - #lower_suffix))
        if before:match("[%-–—]%s*$") then
          text = before:gsub("[%-–—]%s*$", "")
          changed = true
          break
        end
      end
    end
  end
  -- Remove generic trailing markers only at the end.
  local changed = true
  while changed do
    changed = false
    for _, word in ipairs(TRAILING_WORDS) do
      local n = lower(text)
      local w = lower(word)
      if #n > #w and n:sub(-#w - 1) == " " .. w then
        local candidate = util.trim(text:sub(1, #text - #w - 1))
        if candidate ~= "" then
          text = candidate
          changed = true
          break
        end
      end
    end
  end
  return trim_separators(text)
end

--- Clean a title without splitting it. Returns the clean title and a list of
--- version hints found on the way ("live", "remix", ...).
function M.clean_title(raw)
  local text = util.trim(raw)
  local featured, versions = {}, {}

  if text == "" then
    return "", featured, versions
  end

  text = util.html_unescape(text)
  local raw_lower = lower(text)
  local function version_word(word)
    return raw_lower:find("%f[%a]" .. word .. "%f[%A]") ~= nil
  end
  local function add_version(value)
    if not util.contains(versions, value) then
      versions[#versions + 1] = value
    end
  end
  if version_word("live") then add_version("live") end
  if version_word("remix") then add_version("remix") end
  if version_word("acoustic") then add_version("acoustic") end
  if version_word("cover") then add_version("cover") end
  if version_word("instrumental") then add_version("instrumental") end
  if version_word("karaoke") then add_version("karaoke") end
  if raw_lower:find("sped up", 1, true) then add_version("sped up") end
  if raw_lower:find("nightcore", 1, true) then add_version("nightcore") end
  text = text:gsub("\194\160", " ") -- NBSP
  text = text:gsub("\226\128\139", " ") -- zero-width space
  text = text:gsub("\226\128\175", " ") -- zero-width joiner
  text = util.collapse_ws(text)

  text = extract_featured(text, featured)
  text = extract_producer(text)
  text = strip_brackets(text, featured)
  text = strip_edge_phrases(text)

  -- A trailing " - YouTube" or " | Topic" is already handled by the edge list,
  -- but repeated separators can survive. Collapse them once more.
  text = trim_separators(text)

  if text == "" then
    text = util.trim(raw)
  end
  return text, featured, versions
end

--- Split "Artist - Song", "Song – Artist", "Artist // Song" and friends.
function M.split_separator(text)
  text = util.trim(text)
  local separators = { " – ", " — ", " - ", " // ", " | " }
  for _, sep in ipairs(separators) do
    local start = 1
    while true do
      local a, b = text:find(sep, start, true)
      if not a then
        break
      end
      local left = util.trim(text:sub(1, a - 1))
      local right = util.trim(text:sub(b + 1))
      if #left > 0 and #right > 0 and #left <= 80 and #right <= 160 then
        if sep ~= " | " then
          -- "Artist - Song | Album" -> the album tag is not part of the title.
          local before_pipe = right:match("^(.-)%s*|")
          if before_pipe and util.trim(before_pipe) ~= "" then
            right = util.trim(before_pipe)
          end
        end
        return left, right, sep
      end
      start = b + 1
    end
  end
  return nil, nil, nil
end

local function looks_like_credit(text)
  return contains_word(text, {
    "feat", "ft", "featuring", "official", "lyric", "lyrics", "audio",
    "video", "remix", "prod", "records", "music", "topic", "vevo",
  })
end

--- Try the common "Artist 'Song'" and "Artist 「Song」" shapes used by K-pop
--- and J-pop labels, where there is no dash.
local function split_quoted(text)
  local patterns = {
    "^(.+)%s+['\"“](.+)['\"”]%s*$",
    "^(.+)%s+「(.+)」%s*$",
    "^(.+)%s+『(.+)』%s*$",
  }
  for _, pattern in ipairs(patterns) do
    local left, right = text:match(pattern)
    if left and right then
      left = util.trim(left)
      right = util.trim(right)
      if #left > 0 and #right > 0 and #left <= 80 then
        return left, right
      end
    end
  end
  return nil, nil
end

--- Normalize a channel name. Returns the usable artist name, whether the
--- channel looks like a curator/label, and the raw cleaned channel.
function M.clean_channel(raw)
  local name = util.trim(raw)
  if name == "" then
    return "", false, ""
  end
  name = util.html_unescape(name):gsub("%s+", " ")

  name = name:gsub("%s*%-%s*[Tt][Oo][Pp][Ii][Cc]%s*$", "")
  name = name:gsub("%s*[Vv][Ee][Vv][Oo]%s*$", "")
  name = name:gsub("%s*[Oo][Ff][Ff][Ii][Cc][Ii][Aa][Ll]%s*$", "")

  -- "Daft Punk - Archives" -> "Daft Punk" only when the right side is a
  -- generic archive/label suffix.
  local left, right = name:match("^(.-)%s*%-%s*(.+)$")
  if left and right and contains_any(right, { "archive", "archives", "topic", "vevo", "official", "channel", "records" }) then
    name = util.trim(left)
  end

  local function strip_suffix(value, pattern)
    local candidate = util.trim(value:gsub(pattern, ""))
    if candidate ~= "" then
      return candidate
    end
    return value
  end

  name = strip_suffix(name, "%s+[Mm][Uu][Ss][Ii][Cc]%s*$")
  name = strip_suffix(name, "%s+[Rr][Ee][Cc][Oo][Rr][Dd][Ss]%s*$")
  name = strip_suffix(name, "%s+[Hh][Dd]%s*$")
  name = strip_suffix(name, "%s+[4Kk]%s*$")
  name = util.collapse_ws(name)

  local curator = contains_any(name, CURATOR_WORDS)
  return name, curator, util.trim(raw)
end

local function add_query(queries, title, artist, label)
  title = util.trim(title)
  artist = util.trim(artist)
  if title == "" then
    return
  end
  local key = util.normalize(title) .. "|" .. util.normalize(artist)
  for _, query in ipairs(queries) do
    if query.key == key then
      return
    end
  end
  queries[#queries + 1] = {
    title = title,
    artist = artist,
    label = label or "query",
    key = key,
  }
end

local function title_variants(clean_title, raw_title)
  local titles = {}
  add_unique(titles, clean_title)
  -- Drop a parenthetical subtitle only when it survived the noise filter and
  -- the title is long enough that it is probably an annotation.
  local no_parens = clean_title:gsub("%s*%b()", "")
  if no_parens ~= clean_title and #no_parens >= 4 then
    add_unique(titles, util.trim(no_parens))
  end
  local pipe_left, pipe_right = clean_title:match("^(.-)%s*|%s*(.+)$")
  if pipe_left and pipe_right then
    add_unique(titles, util.trim(pipe_left))
    add_unique(titles, util.trim(pipe_right))
  end
  return titles
end

local function artist_variants(parsed_artist, channel_artist, channel_curator, featured)
  local artists = {}
  if parsed_artist and parsed_artist ~= "" then
    add_unique(artists, parsed_artist)
    -- "BTS (방탄소년단)" -> "BTS" is a useful fallback, not the primary.
    local short = parsed_artist:gsub("%s*%b()", "")
    if short ~= parsed_artist and #short >= 2 then
      add_unique(artists, util.trim(short))
    end
    -- "Kygo, Max McNown" benefits from trying the primary artist alone.
    -- Bands such as "Earth, Wind & Fire" must stay intact, so skip the comma
    -- split when an ampersand is present.
    if not parsed_artist:find("&", 1, true) then
      for part in parsed_artist:gmatch("[^,]+") do
        local p = util.trim(part)
        if p ~= "" and p ~= parsed_artist then
          add_unique(artists, p)
        end
      end
    end
  else
    add_unique(artists, channel_artist)
  end
  if channel_artist ~= "" and not channel_curator then
    add_unique(artists, channel_artist)
  end
  for _, name in ipairs(featured or {}) do
    add_unique(artists, name)
  end
  return artists
end

--- Parse a spotatui track table into provider-ready queries.
function M.parse(track)
  track = track or {}
  local raw_title = util.str(track.name)
  local artists = {}
  if type(track.artists) == "table" then
    for _, artist in ipairs(track.artists) do
      if type(artist) == "string" and artist ~= "" then
        artists[#artists + 1] = artist
      end
    end
  end
  local raw_artist = table.concat(artists, ", ")
  local uri = util.str(track.uri)
  local video_id = uri:match("^youtube:(.+)$") or uri:match("^youtube:video:(.+)$")
  local duration_ms = util.num(track.duration_ms, 0)

  local clean_title, featured, versions = M.clean_title(raw_title)
  local channel_artist, channel_curator, channel_raw = M.clean_channel(raw_artist)

  local split_left, split_right = M.split_separator(clean_title)
  local swapped_title, swapped_artist
  local parsed_title = clean_title
  local parsed_artist = nil

  if split_left and split_right then
    -- The usual shape is "Artist - Song", but uploads also use
    -- "Song - Artist" and titles such as "Audio - LSD" where the left side is
    -- a real one-word song name. Keep both directions as query candidates and
    -- pick the primary based on which side looks like a credit/noise token.
    swapped_title = split_left
    swapped_artist = split_right
    if looks_like_credit(split_left) and not looks_like_credit(split_right) then
      parsed_title = split_left
      parsed_artist = split_right
    elseif looks_like_credit(split_right) and not looks_like_credit(split_left) then
      parsed_title = split_left
      parsed_artist = nil
    else
      parsed_title = split_right
      parsed_artist = split_left
    end
  else
    local quoted_artist, quoted_title = split_quoted(clean_title)
    if quoted_artist and quoted_title then
      parsed_artist = quoted_artist
      parsed_title = quoted_title
    end
  end

  parsed_title = util.trim(parsed_title)
  parsed_artist = parsed_artist and util.trim(parsed_artist) or nil

  -- Avoid using an obvious noise string as the artist.
  if parsed_artist and (parsed_artist == "" or is_noise_tag(parsed_artist)) then
    parsed_artist = nil
  end

  local titles = title_variants(parsed_title, raw_title)
  local artists_list = artist_variants(parsed_artist, channel_artist, channel_curator, featured)

  local queries = {}
  local primary_title = titles[1]
  local primary_artist = parsed_artist
  if primary_artist == nil and channel_artist ~= "" and not channel_curator then
    primary_artist = channel_artist
  end

  if primary_artist then
    add_query(queries, primary_title, primary_artist, "title + artist")
  end
  -- LRCLIB often carries the raw YouTube row verbatim, so try it before the
  -- more speculative variants.
  add_query(queries, raw_title, raw_artist, "raw metadata")
  if swapped_title and swapped_artist then
    add_query(queries, swapped_title, swapped_artist, "swapped artist/title")
  end
  if channel_artist ~= "" and not channel_curator and channel_artist ~= primary_artist then
    add_query(queries, primary_title, channel_artist, "title + channel")
  end
  for _, name in ipairs(featured) do
    add_query(queries, primary_title, name, "title + featured")
  end
  for _, artist in ipairs(artists_list) do
    if artist ~= primary_artist and artist ~= channel_artist then
      add_query(queries, primary_title, artist, "title + artist variant")
    end
  end
  for i = 2, #titles do
    add_query(queries, titles[i], primary_artist or channel_artist, "title variant + artist")
  end
  add_query(queries, primary_title, "", "title only")

  local is_music = true
  local reason = "title looks musical"
  local n = lower(raw_title)
  local channel_l = lower(raw_artist)
  if duration_ms > 0 and duration_ms < 30 * 1000 then
    is_music = false
    reason = "too short for a song"
  elseif duration_ms >= 20 * 60 * 1000 then
    is_music = false
    reason = "20 minutes or longer (mix, podcast or stream)"
  elseif n:find("podcast", 1, true) or n:find("interview", 1, true)
    or n:find("tutorial", 1, true) or n:find("reaction", 1, true)
    or n:find("review", 1, true) or n:find("unboxing", 1, true)
    or n:find("gameplay", 1, true) or n:find("stream highlights", 1, true)
    or n:find("how to", 1, true) or n:find("install", 1, true)
    or n:find("course", 1, true) or n:find("lecture", 1, true)
    or n:find("documentary", 1, true) then
    is_music = false
    reason = "title looks like non-music content"
  elseif channel_l:find("podcast", 1, true) or channel_l:find("talk show", 1, true)
    or channel_l:find("news", 1, true) or channel_l:find("comedy", 1, true) then
    is_music = false
    reason = "channel looks like talk content"
  end

  return {
    uri = uri,
    video_id = video_id,
    duration_ms = duration_ms,
    raw_title = raw_title,
    raw_artist = raw_artist,
    title = titles[1],
    artist = parsed_artist or channel_artist,
    parsed_artist = parsed_artist,
    channel_artist = channel_artist,
    channel_curator = channel_curator,
    featured = featured,
    versions = versions,
    titles = titles,
    artists = artists_list,
    swapped_title = swapped_title,
    swapped_artist = swapped_artist,
    queries = queries,
    is_music = is_music,
    reason = reason,
    debug = {
      "raw title: " .. raw_title,
      "raw channel: " .. raw_artist,
      "clean channel: " .. (channel_raw ~= "" and channel_raw or "(none)"),
      "clean title: " .. clean_title,
      "parsed title: " .. (parsed_title ~= "" and parsed_title or "(none)"),
      "parsed artist: " .. (parsed_artist or "(none)"),
      "channel artist: " .. (channel_artist ~= "" and channel_artist or "(none)"),
      "channel curator: " .. tostring(channel_curator),
      "featured: " .. (#featured > 0 and table.concat(featured, ", ") or "(none)"),
      "versions: " .. (#versions > 0 and table.concat(versions, ", ") or "(none)"),
    },
  }
end

return M
