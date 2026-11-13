-- Runtime configuration, read once at load time.
--
-- spotatui plugins have no settings UI, so configuration is environment based.
-- Everything is optional; the defaults are the recommended setup.

local util = require("ytlyrics.util")

local M = {}

local KNOWN_PROVIDERS = {
  lrclib = true,
  netease = true,
  genius = true,
}

local function env(name, default)
  local value = os.getenv(name)
  if value == nil or value == "" then
    return default
  end
  return value
end

local function env_number(name, default, low, high)
  local value = tonumber(env(name, ""))
  if not value then
    return default
  end
  return util.clamp(value, low, high)
end

local function parse_list(value, allowed)
  local out = {}
  for part in tostring(value):gmatch("[^,;%s]+") do
    local name = util.trim(part):lower()
    if name ~= "" and (not allowed or allowed[name]) and not util.contains(out, name) then
      out[#out + 1] = name
    end
  end
  return out
end

M.providers = parse_list(env("SPOTATUI_LYRICS_PROVIDERS", "lrclib,genius"), KNOWN_PROVIDERS)
if #M.providers == 0 then
  M.providers = { "lrclib" }
end

M.sources = parse_list(env("SPOTATUI_LYRICS_SOURCES", "youtube"), nil)
if #M.sources == 0 then
  M.sources = { "youtube" }
end

M.prefetch = env("SPOTATUI_LYRICS_PREFETCH", "0") == "1"
M.estimate = env("SPOTATUI_LYRICS_ESTIMATE", "1") ~= "0"
M.debug = env("SPOTATUI_LYRICS_DEBUG", "0") == "1"
M.context_lines = env_number("SPOTATUI_LYRICS_CONTEXT", 6, 2, 20)
M.offset_step_ms = env_number("SPOTATUI_LYRICS_OFFSET_STEP", 250, 50, 2000)
M.bias_ms = env_number("SPOTATUI_LYRICS_BIAS_MS", 120, -1000, 1000)
M.timeout_ms = env_number("SPOTATUI_LYRICS_TIMEOUT", 15000, 3000, 30000)
M.max_body_bytes = env_number("SPOTATUI_LYRICS_MAX_BODY", 2097152, 65536, 8388608)
M.genius_browser_fallback = env("SPOTATUI_LYRICS_GENIUS_POST", "1") ~= "0"
M.max_queries = env_number("SPOTATUI_LYRICS_MAX_QUERIES", 4, 1, 8)

M.screen_name = "ytlyrics"
M.command_prefix = "ytlyrics_"

--- Whether the plugin should handle the currently playing source.
function M.source_enabled(uri)
  if util.contains(M.sources, "all") then
    return true
  end
  if not uri then
    return false
  end
  if uri:match("^youtube:") then
    return util.contains(M.sources, "youtube")
  end
  return false
end

return M
