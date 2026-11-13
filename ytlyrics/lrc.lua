-- LRC parsing and plain-lyrics timing estimation.
--
-- Providers return either timestamps (LRCLIB synced, NetEase LRC) or plain
-- text (Genius). Both end up as the same line table so the UI has one shape:
--   { time_ms = number, text = string, is_header = boolean }

local util = require("ytlyrics.util")

local M = {}

local function parse_fraction(fraction)
  if fraction == nil or fraction == "" then
    return 0
  end
  fraction = fraction:sub(1, 3)
  if #fraction == 1 then
    return tonumber(fraction) * 100
  elseif #fraction == 2 then
    return tonumber(fraction) * 10
  end
  return tonumber(fraction) or 0
end

local function parse_stamp(tag)
  tag = util.trim(tag)
  if tag == "" then
    return nil
  end

  local h, m, s, frac = tag:match("^(%d+):(%d+):(%d+)%.(%d+)$")
  if h then
    return tonumber(h) * 3600000 + tonumber(m) * 60000 + tonumber(s) * 1000 + parse_fraction(frac)
  end

  -- LRC's "mm:ss:xx" (colon before centiseconds) is far more common than a
  -- three-component hh:mm:ss stamp. Prefer it when both fields look like
  -- minutes/seconds.
  m, s, frac = tag:match("^(%d+):(%d+):(%d+)$")
  if m and tonumber(m) < 60 and tonumber(s) < 60 then
    return tonumber(m) * 60000 + tonumber(s) * 1000 + parse_fraction(frac)
  end

  m, s, frac = tag:match("^(%d+):(%d+)%.(%d+)$")
  if m then
    return tonumber(m) * 60000 + tonumber(s) * 1000 + parse_fraction(frac)
  end

  h, m, s = tag:match("^(%d+):(%d+):(%d+)$")
  if h then
    return tonumber(h) * 3600000 + tonumber(m) * 60000 + tonumber(s) * 1000
  end

  m, s = tag:match("^(%d+):(%d+)$")
  if m then
    return tonumber(m) * 60000 + tonumber(s) * 1000
  end

  return nil
end

local function strip_inline_timestamps(text)
  -- Enhanced LRC word timing: <00:12.34>word
  text = text:gsub("<%d+:%d+[%.%:]%d+>", "")
  -- Karaoke/agent tags sometimes look like {\\kf...}; leave ordinary braces.
  text = text:gsub("{\\[^}]*}", "")
  return text
end

local function is_header(text)
  return text:match("^%[.-%]$") ~= nil
end

local CREDIT_WORDS = {
  "作词", "作曲", "编曲", "制作人", "出品", "监制", "混音", "母带", "录音",
  "和声", "吉他", "贝斯", "鼓", "键盘", "弦乐", "词", "曲",
  "lyrics by", "composed by", "written by", "produced by", "arranged by",
  "mixed by", "mastered by", "performed by", "music by", "label:",
}

local function is_credit(text)
  local n = util.normalize(text)
  for _, word in ipairs(CREDIT_WORDS) do
    local w = util.normalize(word)
    if w ~= "" and n:find(w, 1, true) then
      -- Chinese credits are usually followed by a colon; avoid eating a
      -- lyric that merely contains the character.
      if #w > 1 or n:find(" : ", 1, true) or n:find("：", 1, true) then
        return true
      end
    end
  end
  return false
end

local function is_artifact(text)
  local n = util.normalize(text)
  return n == "you might also like"
    or n == "embed"
    or n == "read more"
    or n == "lyrics"
    or n == "ad"
    or is_credit(text)
end

--- Split raw text into clean, non-empty display lines.
function M.clean_lines(text)
  if type(text) ~= "string" then
    return {}
  end
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  text = util.html_unescape(text)
  local out = {}
  for _, raw in ipairs(util.split(text, "\n")) do
    local line = util.trim(raw:gsub("\194\160", " "))
    if line ~= "" and not is_artifact(line) then
      out[#out + 1] = line
    end
  end
  return out
end

--- Parse an LRC document. Returns synced lines when timestamps exist,
--- otherwise the clean plain text.
function M.parse(text)
  local result = {
    lines = {},
    synced = false,
    estimated = false,
    offset_ms = 0,
    plain_text = "",
  }
  if type(text) ~= "string" or text == "" then
    return result
  end

  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local untimed = {}
  local offset = 0
  local entries = {}

  for _, raw in ipairs(util.split(text, "\n")) do
    local line = util.trim(raw)
    if line ~= "" then
      local tags, pos = {}, 1
      while line:sub(pos, pos) == "[" do
        local close = line:find("]", pos, true)
        if not close then
          break
        end
        tags[#tags + 1] = line:sub(pos + 1, close - 1)
        pos = close + 1
      end

      local content = util.trim(line:sub(pos))
      local times, extra_tags = {}, {}
      for _, tag in ipairs(tags) do
        local stamp = parse_stamp(tag)
        if stamp then
          times[#times + 1] = stamp
        elseif tag:match("^[Oo][Ff][Ff][Ss][Ee][Tt]:") then
          local value = tag:match("^[Oo][Ff][Ff][Ss][Ee][Tt]:([%+%-]?%d+)")
          offset = tonumber(value) or offset
        elseif tag:match("^[%a#]+:") then
          -- [ar:], [ti:], [al:], [by:], [length:], ... are metadata.
        else
          extra_tags[#extra_tags + 1] = tag
        end
      end

      if content == "" and #extra_tags > 0 then
        content = "[" .. table.concat(extra_tags, "][") .. "]"
      end
      content = strip_inline_timestamps(content)
      content = util.trim(content)

      if content ~= "" and is_credit(content) then
        content = ""
      end

      if #times > 0 then
        for _, stamp in ipairs(times) do
          entries[#entries + 1] = {
            time_ms = math.max(0, stamp - offset),
            text = content,
            is_header = is_header(content),
            order = #entries + 1,
          }
        end
      elseif content ~= "" then
        untimed[#untimed + 1] = content
      end
    end
  end

  -- A file with no timestamps at all is plain lyrics.
  if #entries == 0 then
    result.plain_text = table.concat(untimed, "\n")
    return result
  end

  -- Timestamps but a single instant (or all zero) are not real sync either.
  local distinct, min_t, max_t = {}, nil, nil
  for _, entry in ipairs(entries) do
    distinct[entry.time_ms] = true
    min_t = min_t and math.min(min_t, entry.time_ms) or entry.time_ms
    max_t = max_t and math.max(max_t, entry.time_ms) or entry.time_ms
  end
  local distinct_count = 0
  for _ in pairs(distinct) do
    distinct_count = distinct_count + 1
  end
  if #entries > 1 and (distinct_count <= 1 or (max_t or 0) - (min_t or 0) < 500) then
    -- Keep the text, drop the useless timestamps.
    local texts = {}
    for _, entry in ipairs(entries) do
      if entry.text ~= "" then
        texts[#texts + 1] = entry.text
      end
    end
    result.plain_text = table.concat(texts, "\n")
    return result
  end

  -- Long LRC lines are occasionally wrapped as a timestamped line plus an
  -- untimed continuation. Attach leftovers to the previous timed line.
  if #untimed > 0 then
    local last = entries[#entries]
    if last then
      last.text = util.trim(last.text .. " " .. table.concat(untimed, " "))
    end
  end

  table.sort(entries, function(a, b)
    if a.time_ms == b.time_ms then
      return a.order < b.order
    end
    return a.time_ms < b.time_ms
  end)

  local lines = {}
  for _, entry in ipairs(entries) do
    if entry.text ~= "" then
      lines[#lines + 1] = {
        time_ms = entry.time_ms,
        text = entry.text,
        is_header = entry.is_header,
      }
    end
  end

  if #lines == 0 then
    result.plain_text = table.concat(untimed, "\n")
    return result
  end

  result.lines = lines
  result.synced = true
  result.offset_ms = offset
  return result
end

local function timed_weights(lines)
  local weights, total = {}, 0
  for _, line in ipairs(lines) do
    local weight = util.clamp(util.utf8_len(line.text) + 4, 8, 120)
    weights[#weights + 1] = weight
    total = total + weight
  end
  return weights, total
end

--- Attach estimated timestamps to plain text. This is not true sync: it is a
--- readable, monotonic timeline used when no provider has real timestamps.
function M.parse_plain(text, duration_ms)
  local plain = M.clean_lines(text)
  local lines = {}
  for _, line in ipairs(plain) do
    lines[#lines + 1] = {
      time_ms = 0,
      text = line,
      is_header = is_header(line),
    }
  end

  local timed = {}
  for _, line in ipairs(lines) do
    if not line.is_header then
      timed[#timed + 1] = line
    end
  end

  if #timed == 0 then
    return {
      lines = lines,
      synced = false,
      estimated = false,
      plain_text = table.concat(plain, "\n"),
    }
  end

  duration_ms = tonumber(duration_ms) or 0
  local lead = 0
  local tail = 0
  if duration_ms > 5000 then
    lead = math.min(3000, duration_ms * 0.02)
    tail = math.min(3000, duration_ms * 0.03)
  end

  local weights, total = timed_weights(timed)
  local available = duration_ms > 0 and math.max(1000, duration_ms - lead - tail) or 0
  local cursor = lead
  for i, line in ipairs(timed) do
    if available > 0 then
      line.time_ms = math.floor(cursor + 0.5)
      cursor = cursor + (weights[i] / total) * available
    else
      line.time_ms = (i - 1) * 4000
    end
  end

  -- Put section headers just before the next real line so they scroll with it.
  local last_time = 0
  for i, line in ipairs(lines) do
    if line.is_header then
      local next_time = last_time
      for j = i + 1, #lines do
        if not lines[j].is_header then
          next_time = lines[j].time_ms
          break
        end
      end
      line.time_ms = math.max(0, next_time - 1)
    else
      last_time = line.time_ms
    end
  end

  return {
    lines = lines,
    synced = false,
    estimated = true,
    plain_text = table.concat(plain, "\n"),
  }
end

--- Last non-header line at or before progress_ms, or the first line.
function M.line_index(lines, progress_ms, offset_ms)
  offset_ms = offset_ms or 0
  if not lines or #lines == 0 then
    return nil
  end
  local target = progress_ms - offset_ms
  local found = nil
  for i, line in ipairs(lines) do
    if not line.is_header then
      if line.time_ms <= target then
        found = i
      else
        break
      end
    end
  end
  if found then
    return found
  end
  for i, line in ipairs(lines) do
    if not line.is_header then
      return i
    end
  end
  return 1
end

function M.next_index(lines, index)
  if not lines then
    return nil
  end
  local i = (index or 0) + 1
  while i <= #lines do
    if not lines[i].is_header then
      return i
    end
    i = i + 1
  end
  return index
end

function M.prev_index(lines, index)
  if not lines then
    return nil
  end
  local i = (index or #lines + 1) - 1
  while i >= 1 do
    if not lines[i].is_header then
      return i
    end
    i = i - 1
  end
  return index
end

return M
