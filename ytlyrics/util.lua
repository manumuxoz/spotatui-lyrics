-- Shared string, table and encoding helpers.
-- Kept dependency-free: this module runs inside spotatui's embedded Lua 5.4.

local M = {}

local ACCENTS = {
  { "á", "a" }, { "à", "a" }, { "â", "a" }, { "ä", "a" }, { "ã", "a" },
  { "å", "a" }, { "ā", "a" }, { "ă", "a" }, { "ą", "a" },
  { "Á", "A" }, { "À", "A" }, { "Â", "A" }, { "Ä", "A" }, { "Ã", "A" },
  { "Å", "A" }, { "Ā", "A" }, { "Ă", "A" }, { "Ą", "A" },
  { "é", "e" }, { "è", "e" }, { "ê", "e" }, { "ë", "e" }, { "ē", "e" },
  { "ĕ", "e" }, { "ė", "e" }, { "ę", "e" }, { "ě", "e" },
  { "É", "E" }, { "È", "E" }, { "Ê", "E" }, { "Ë", "E" }, { "Ē", "E" },
  { "Ĕ", "E" }, { "Ė", "E" }, { "Ę", "E" }, { "Ě", "E" },
  { "í", "i" }, { "ì", "i" }, { "î", "i" }, { "ï", "i" }, { "ī", "i" },
  { "ĭ", "i" }, { "į", "i" }, { "ı", "i" },
  { "Í", "I" }, { "Ì", "I" }, { "Î", "I" }, { "Ï", "I" }, { "Ī", "I" },
  { "Ĭ", "I" }, { "Į", "I" }, { "İ", "I" },
  { "ó", "o" }, { "ò", "o" }, { "ô", "o" }, { "ö", "o" }, { "õ", "o" },
  { "ø", "o" }, { "ō", "o" }, { "ŏ", "o" }, { "ő", "o" },
  { "Ó", "O" }, { "Ò", "O" }, { "Ô", "O" }, { "Ö", "O" }, { "Õ", "O" },
  { "Ø", "O" }, { "Ō", "O" }, { "Ŏ", "O" }, { "Ő", "O" },
  { "ú", "u" }, { "ù", "u" }, { "û", "u" }, { "ü", "u" }, { "ū", "u" },
  { "ŭ", "u" }, { "ů", "u" }, { "ű", "u" }, { "ų", "u" },
  { "Ú", "U" }, { "Ù", "U" }, { "Û", "U" }, { "Ü", "U" }, { "Ū", "U" },
  { "Ŭ", "U" }, { "Ů", "U" }, { "Ű", "U" }, { "Ų", "U" },
  { "ñ", "n" }, { "ń", "n" }, { "ň", "n" }, { "Ñ", "N" }, { "Ń", "N" },
  { "Ň", "N" },
  { "ç", "c" }, { "ć", "c" }, { "č", "c" }, { "Ç", "C" }, { "Ć", "C" },
  { "Č", "C" },
  { "ý", "y" }, { "ÿ", "y" }, { "Ý", "Y" }, { "Ÿ", "Y" },
  { "ř", "r" }, { "Ř", "R" }, { "š", "s" }, { "Š", "S" }, { "ž", "z" },
  { "Ž", "Z" }, { "ď", "d" }, { "Ď", "D" }, { "ť", "t" }, { "Ť", "T" },
  { "ğ", "g" }, { "Ğ", "G" }, { "ş", "s" }, { "Ş", "S" },
  { "ß", "ss" }, { "æ", "ae" }, { "Æ", "AE" }, { "œ", "oe" }, { "Œ", "OE" },
}

function M.trim(s)
  if type(s) ~= "string" then
    return ""
  end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.collapse_ws(s)
  if type(s) ~= "string" then
    return ""
  end
  return (s:gsub("%s+", " "))
end

function M.strip_accents(s)
  if type(s) ~= "string" then
    return ""
  end
  for _, pair in ipairs(ACCENTS) do
    s = s:gsub(pair[1], pair[2])
  end
  return s
end

--- Lowercase + accent folding + punctuation folding, used for comparisons.
--- Keeps non-Latin UTF-8 letters intact, so Japanese/Cyrillic titles still
--- compare as tokens instead of collapsing to an empty string.
function M.normalize(s)
  if type(s) ~= "string" then
    return ""
  end
  s = M.strip_accents(s)
  s = s:lower()
  s = s:gsub("['’`´]", "")
  s = s:gsub("&", " and ")
  s = s:gsub("[%p%c]", " ")
  s = s:gsub("%s+", " ")
  return M.trim(s)
end

--- Normalized form with a leading English article removed.
function M.normalize_title(s)
  local n = M.normalize(s)
  n = n:gsub("^the%s+", "")
  n = n:gsub("^a%s+", "")
  n = n:gsub("^an%s+", "")
  return n
end

function M.tokens(s)
  local out = {}
  for token in M.normalize(s):gmatch("%S+") do
    out[#out + 1] = token
  end
  return out
end

function M.utf8_len(s)
  if type(s) ~= "string" then
    return 0
  end
  if utf8 and utf8.len then
    local n = utf8.len(s)
    if n then
      return n
    end
  end
  return #s
end

function M.shorten(s, max_chars)
  if type(s) ~= "string" or max_chars < 1 then
    return ""
  end
  if M.utf8_len(s) <= max_chars then
    return s
  end
  if utf8 and utf8.offset then
    local offset = utf8.offset(s, max_chars)
    if offset then
      return s:sub(1, offset - 1) .. "…"
    end
  end
  return s:sub(1, max_chars - 1) .. "…"
end

--- Percent-encode every byte outside the RFC 3986 unreserved set.
function M.urlencode(s)
  if type(s) ~= "string" then
    return ""
  end
  return (s:gsub("([^%w%-%._~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local HTML_ENTITIES = {
  amp = "&", lt = "<", gt = ">", quot = '"', apos = "'",
  nbsp = " ", ndash = "–", mdash = "—", hellip = "…",
  lsquo = "‘", rsquo = "’", ldquo = "“", rdquo = "”",
  laquo = "«", raquo = "»", copy = "©", reg = "®",
  trade = "™", deg = "°", middot = "·", bull = "•",
  eacute = "é", egrave = "è", agrave = "à", ccedil = "ç",
  uuml = "ü", ouml = "ö", auml = "ä", ntilde = "ñ",
}

function M.html_unescape(s)
  if type(s) ~= "string" then
    return ""
  end
  return (s:gsub("&(#?[%w]+);", function(entity)
    local named = HTML_ENTITIES[entity]
    if named then
      return named
    end
    if entity:sub(1, 1) == "#" then
      local code
      if entity:sub(2, 2):lower() == "x" then
        code = tonumber(entity:sub(3), 16)
      else
        code = tonumber(entity:sub(2), 10)
      end
      if code and code > 0 and code <= 0x10FFFF then
        local ok, ch = pcall(utf8.char, code)
        if ok then
          return ch
        end
      end
    end
    return "&" .. entity .. ";"
  end))
end

--- spotatui decodes JSON null to a light userdata sentinel. Treat any
--- userdata as "missing" so provider code can use plain nil checks.
function M.is_null(v)
  return v ~= nil and type(v) == "userdata"
end

function M.str(v, default)
  if type(v) == "string" then
    return v
  end
  return default or ""
end

function M.num(v, default)
  if type(v) == "number" then
    return v
  end
  return default or 0
end

function M.table(v)
  if type(v) == "table" then
    return v
  end
  return {}
end

function M.clamp(n, low, high)
  if n < low then
    return low
  end
  if n > high then
    return high
  end
  return n
end

function M.round(n)
  if n >= 0 then
    return math.floor(n + 0.5)
  end
  return math.ceil(n - 0.5)
end

function M.fmt_ms(ms)
  ms = math.max(0, math.floor(tonumber(ms) or 0))
  local total = math.floor(ms / 1000)
  local minutes = math.floor(total / 60)
  local seconds = total % 60
  return string.format("%d:%02d", minutes, seconds)
end

--- Split a string on a plain separator. `max_parts` defaults to unlimited.
function M.split(s, sep, max_parts)
  local out = {}
  if type(s) ~= "string" or s == "" then
    return out
  end
  if sep == "" then
    return { s }
  end
  local start = 1
  while true do
    if max_parts and #out == max_parts - 1 then
      out[#out + 1] = s:sub(start)
      break
    end
    local a, b = s:find(sep, start, true)
    if not a then
      out[#out + 1] = s:sub(start)
      break
    end
    out[#out + 1] = s:sub(start, a - 1)
    start = b + 1
    if start > #s then
      out[#out + 1] = ""
      break
    end
  end
  return out
end

function M.dedupe(list, key_fn)
  local seen, out = {}, {}
  for _, item in ipairs(list) do
    local key = key_fn and key_fn(item) or item
    if key ~= nil and key ~= "" and not seen[key] then
      seen[key] = true
      out[#out + 1] = item
    end
  end
  return out
end

function M.contains(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

function M.copy(tbl)
  local out = {}
  for k, v in pairs(tbl or {}) do
    out[k] = v
  end
  return out
end

return M
