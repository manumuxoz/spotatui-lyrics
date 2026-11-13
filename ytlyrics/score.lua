-- Match scoring for provider results.
--
-- A YouTube title is noisy and the channel is often not the artist, so a
-- provider hit is accepted only when title, artist and duration agree well
-- enough. The weights are deliberately conservative: a wrong song with
-- perfectly synced timestamps is worse than a plain-text right song.

local util = require("ytlyrics.util")

local M = {}

local function levenshtein(a, b)
  if a == b then
    return 0
  end
  if a == "" then
    return #b
  end
  if b == "" then
    return #a
  end
  if #a > 120 then
    a = a:sub(1, 120)
  end
  if #b > 120 then
    b = b:sub(1, 120)
  end
  local prev, curr = {}, {}
  for j = 0, #b do
    prev[j] = j
  end
  for i = 1, #a do
    curr[0] = i
    local ca = a:byte(i)
    for j = 1, #b do
      local cost = ca == b:byte(j) and 0 or 1
      local delete = prev[j] + 1
      local insert = curr[j - 1] + 1
      local replace = prev[j - 1] + cost
      curr[j] = math.min(delete, insert, replace)
    end
    prev, curr = curr, prev
  end
  return prev[#b]
end

local function token_set(s)
  local set = {}
  for _, token in ipairs(util.tokens(s)) do
    set[token] = true
  end
  return set
end

local function jaccard(a, b)
  local sa, sb = token_set(a), token_set(b)
  local inter, union = 0, 0
  for token in pairs(sa) do
    union = union + 1
    if sb[token] then
      inter = inter + 1
    end
  end
  for token in pairs(sb) do
    if not sa[token] then
      union = union + 1
    end
  end
  if union == 0 then
    return 0
  end
  return inter / union
end

--- Generic title/artist string similarity in [0, 1].
function M.similarity(a, b)
  local na, nb = util.normalize_title(a), util.normalize_title(b)
  if na == "" or nb == "" then
    return 0
  end
  if na == nb then
    return 1
  end
  local shorter, longer = na, nb
  if #shorter > #longer then
    shorter, longer = longer, shorter
  end
  if #shorter >= 3 and #shorter / #longer >= 0.5 and longer:find(shorter, 1, true) then
    return 0.9
  end
  local lev = 1 - levenshtein(na, nb) / math.max(#na, #nb)
  local jac = jaccard(na, nb)
  return math.max(lev * 0.95, jac)
end


local VERSION_TAGS = {
  "feat", "ft", "featuring", "remaster", "remastered", "version", "live",
  "radio edit", "acoustic", "official", "lyrics", "lyric", "audio", "video",
  "remix", "extended", "demo", "instrumental", "karaoke", "sped up",
  "nightcore", "slowed", "reverb", "8d", "explicit", "clean",
}

local function clean_result_title(value)
  local text = tostring(value or "")
  text = text:gsub("%s*%b()", function(inner)
    local n = util.normalize(inner)
    for _, tag in ipairs(VERSION_TAGS) do
      if n:find(tag, 1, true) then
        return ""
      end
    end
    return nil
  end)
  text = text:gsub("%s*%b[]", function(inner)
    local n = util.normalize(inner)
    for _, tag in ipairs(VERSION_TAGS) do
      if n:find(tag, 1, true) then
        return ""
      end
    end
    return nil
  end)
  text = text:gsub("(%f[%w][Ff][Ee][Aa][Tt]%.?%s+.*)$", "")
  text = text:gsub("(%f[%w][Ff][Tt]%.?%s+.*)$", "")
  text = text:gsub("%s+$", "")
  return text
end

local function score_normalized(a, b)
  if a == "" or b == "" then
    return 0
  end
  if a == b then
    return 1
  end

  -- "Get Lucky" vs "Get Lucky (feat. Pharrell Williams)".
  local shorter, longer = a, b
  if #shorter > #longer then
    shorter, longer = longer, shorter
  end
  if #shorter >= 6 and #shorter / #longer >= 0.55 and longer:find(shorter, 1, true) then
    return 0.92
  end
  -- A provider title often appends a credit or version tag that the bracket
  -- cleaner did not recognise. A clean prefix is still a strong match.
  if #shorter >= 3 and longer:sub(1, #shorter) == shorter then
    local next_char = longer:sub(#shorter + 1, #shorter + 1)
    if next_char == "" or next_char:match("[%s%-–—%(%)%[%]|/,;:]") then
      return 0.9
    end
  end

  local score = math.max(jaccard(a, b), (1 - levenshtein(a, b) / math.max(#a, #b)) * 0.95)
  -- One-token titles ("Happy", "Hello") are common; require a strong token
  -- match rather than a lucky substring.
  local ta = util.tokens(a)
  local tb = util.tokens(b)
  if #ta == 1 and #tb >= 1 then
    for _, token in ipairs(tb) do
      if token == ta[1] then
        score = math.max(score, 0.82)
        break
      end
    end
  end
  return util.clamp(score, 0, 1)
end

function M.title_score(query_title, result_title)
  local a = util.normalize_title(query_title)
  if a == "" then
    return 0
  end
  local cleaned = clean_result_title(result_title)
  local candidates = { util.normalize_title(cleaned) }
  -- LRCLIB contains many rows whose trackName is the whole YouTube title
  -- ("Artist - Song (Official Video)"). Compare both sides of a spaced dash
  -- as well as the full string, so those rows still match.
  local left, right = cleaned:match("^(.-)%s+[%-–—]%s+(.+)$")
  if left and right then
    candidates[#candidates + 1] = util.normalize_title(left)
    candidates[#candidates + 1] = util.normalize_title(right)
  end
  local best = 0
  for _, b in ipairs(candidates) do
    best = math.max(best, score_normalized(a, b))
  end
  return best
end

local function artist_variants(value)
  local out = { value }
  for part in tostring(value):gmatch("[^,&]+") do
    local p = util.trim(part)
    if p ~= "" and p ~= value then
      out[#out + 1] = p
    end
  end
  return out
end

function M.artist_score(query_artist, result_artist, query_is_curator)
  if query_artist == nil or util.trim(query_artist) == "" then
    return 0.5, "unknown query artist"
  end
  if query_is_curator then
    return 0.5, "curator channel"
  end
  local best = 0
  for _, candidate in ipairs(artist_variants(query_artist)) do
    for _, result in ipairs(artist_variants(result_artist)) do
      best = math.max(best, M.similarity(candidate, result))
    end
  end
  return best, nil
end

function M.duration_score(query_ms, result_ms)
  if not query_ms or query_ms <= 0 or not result_ms or result_ms <= 0 then
    return 0.5, "unknown duration"
  end
  local diff = math.abs(query_ms - result_ms) / 1000
  if diff <= 2 then
    return 1.0, nil
  elseif diff <= 5 then
    return 0.9, nil
  elseif diff <= 10 then
    return 0.75, nil
  elseif diff <= 20 then
    return 0.55, nil
  elseif diff <= 35 then
    return 0.35, nil
  end
  return 0.1, string.format("duration differs by %.0fs", diff)
end

--- Score one provider result against one query.
function M.score(query, result, opts)
  opts = opts or {}
  local title = M.title_score(query.title, result.title)
  local artist, artist_reason = M.artist_score(query.artist, result.artist, query.is_curator)
  local duration, duration_reason = M.duration_score(query.duration_ms, result.duration_ms)

  local weights
  if query.artist == nil or util.trim(query.artist) == "" or query.is_curator then
    weights = { title = 0.7, artist = 0.0, duration = 0.3 }
  else
    weights = { title = 0.55, artist = 0.25, duration = 0.2 }
  end

  local total = title * weights.title + artist * weights.artist + duration * weights.duration

  -- A synced album version can be minutes longer than the YouTube video
  -- (intro/outro/radio edit). Its timestamps are then useless even when the
  -- title and artist match perfectly, so penalise the total instead of
  -- treating duration as a minor 20% term.
  local diff = 0
  if query.duration_ms and query.duration_ms > 0
    and result.duration_ms and result.duration_ms > 0 then
    diff = math.abs(query.duration_ms - result.duration_ms) / 1000
  end
  local penalty = 1
  if diff > 60 then
    penalty = 0.6
  elseif diff > 30 then
    penalty = 0.75
  elseif diff > 15 then
    penalty = 0.9
  end

  return {
    total = util.clamp(total * penalty, 0, 1),
    title = title,
    artist = artist,
    duration = duration,
    duration_diff_s = diff,
    reason = artist_reason or duration_reason,
  }
end

--- Score and sort provider results in place. Higher is better; synced wins
--- ties because it is strictly more useful.
function M.rank(results, query, opts)
  for _, result in ipairs(results) do
    result.score = M.score(query, result, opts)
    result.effective = result.score.total + (result.synced and 0.05 or 0)
  end
  table.sort(results, function(a, b)
    if a.effective == b.effective then
      if a.synced ~= b.synced then
        return a.synced
      end
      return (a.title or "") < (b.title or "")
    end
    return a.effective > b.effective
  end)
  return results
end

function M.is_confident(result, threshold)
  threshold = threshold or 0.72
  return result and result.score and result.score.total >= threshold
end

function M.summary(result)
  if not result then
    return "no match"
  end
  local score = result.score and result.score.total or 0
  return string.format(
    "%s · %.0f%% · %s%s",
    result.provider or "?",
    score * 100,
    result.synced and "synced" or "text",
    result.score and result.score.reason and (" · " .. result.score.reason) or ""
  )
end

return M
