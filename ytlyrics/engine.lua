-- Lookup orchestration: metadata -> queries -> providers -> ranked result.
--
-- The chain is sequential on purpose. It stops as soon as a high-confidence
-- synced result appears, keeps a plain result as a fallback while it looks for
-- timestamps in the next provider, and cancels every late callback through a
-- generation token.

local util = require("ytlyrics.util")
local metadata = require("ytlyrics.metadata")
local lrc = require("ytlyrics.lrc")
local score = require("ytlyrics.score")
local cache_mod = require("ytlyrics.cache")
local i18n = require("ytlyrics.i18n")

local Engine = {}
Engine.__index = Engine

local PROVIDERS = {
  lrclib = require("ytlyrics.providers.lrclib"),
  lrcmux = require("ytlyrics.providers.lrcmux"),
  ytmusic = require("ytlyrics.providers.youtube_music"),
  netease = require("ytlyrics.providers.netease"),
  genius = require("ytlyrics.providers.genius"),
}

local function log(message)
  if spotatui and spotatui.log then
    spotatui.log("[ytlyrics] " .. tostring(message))
  end
end

local function read_number(key, default)
  local value = spotatui.storage_get(key)
  if type(value) == "number" then
    return value
  end
  return default
end

function Engine.new(opts)
  opts = opts or {}
  local self = setmetatable({
    config = opts.config,
    http = opts.http,
    cache = cache_mod.new(24),
    generation = 0,
    current_uri = nil,
    info = nil,
    provider_list = {},
    state = {
      status = "idle",
      lines = {},
      offset_ms = 0,
      variant = 1,
      variant_count = 1,
      synced = false,
      estimated = false,
      debug = {},
    },
    last_debug = {},
    on_update = nil,
    on_message = nil,
  }, Engine)

  for _, name in ipairs(self.config.providers) do
    local provider = PROVIDERS[name]
    if provider then
      self.provider_list[#self.provider_list + 1] = provider
    end
  end
  if #self.provider_list == 0 then
    self.provider_list[1] = PROVIDERS.lrclib
  end
  return self
end

function Engine:notify_update()
  if self.on_update then
    local ok, err = pcall(self.on_update, self.state)
    if not ok then
      log("on_update failed: " .. tostring(err))
    end
  end
end

function Engine:debug(message)
  self.last_debug[#self.last_debug + 1] = tostring(message)
  if self.config.debug then
    log(message)
  end
end

function Engine:reset_state(reason)
  self.state = {
    status = "idle",
    lines = {},
    offset_ms = 0,
    variant = 1,
    variant_count = 1,
    synced = false,
    estimated = false,
    plain_text = "",
    provider = nil,
    score = nil,
    error = reason,
    debug = {},
  }
  self.info = nil
  self.current_uri = nil
end

function Engine:load_preferences(info)
  local id = info and info.video_id or nil
  if not id then
    return 1, 0
  end
  local variant = math.floor(read_number("variant:" .. id, 1))
  if variant < 1 then
    variant = 1
  end
  local offset = math.floor(read_number("offset:" .. id, 0))
  offset = util.clamp(offset, -30000, 30000)
  return variant, offset
end

function Engine:save_variant(info, variant)
  if info and info.video_id then
    spotatui.storage_set("variant:" .. info.video_id, variant)
  end
end

function Engine:save_offset(info, offset)
  if info and info.video_id then
    spotatui.storage_set("offset:" .. info.video_id, offset)
  end
end

--- Apply a final result to the visible state.
function Engine:apply_result(result, info, debug, extra)
  extra = extra or {}
  local duration = info and info.duration_ms or 0
  local lines = {}
  local synced = false
  local estimated = false
  local plain_text = ""

  if result and result.synced and type(result.lines) == "table" and #result.lines > 0 then
    lines = result.lines
    synced = true
  elseif result and type(result.plain_text) == "string" and result.plain_text ~= "" then
    plain_text = result.plain_text
    local parsed = lrc.parse_plain(plain_text, duration)
    lines = parsed.lines
    estimated = self.config.estimate and parsed.estimated or false
  elseif result and type(result.lines) == "table" and #result.lines > 0 then
    lines = result.lines
    estimated = true
  end

  self.state = {
    status = #lines > 0 and "ready" or "empty",
    lines = lines,
    plain_text = plain_text,
    synced = synced,
    estimated = estimated,
    provider = result and result.provider or nil,
    provider_id = result and result.provider_id or nil,
    score = result and result.score or nil,
    low_confidence = result and result.score and result.score.total < 0.7 or false,
    error = nil,
    debug = debug or {},
    offset_ms = self.state.offset_ms or 0,
    variant = self.state.variant or 1,
    variant_count = self.state.variant_count or 1,
    url = result and result.url or nil,
    result = result,
    matched_title = result and result.title or nil,
    matched_artist = result and result.artist or nil,
    duration_ms = duration,
    timeout = extra.timeout == true,
    provisional = extra.provisional == true,
    searching = extra.searching == true,
  }

  if not extra.provisional then
    local key = (info and info.uri or "") .. "#" .. tostring(self.state.variant)
    self.cache:set(key, util.copy(self.state))
  end
  self:notify_update()
end

function Engine:finish_empty(info, debug, errors, extra)
  extra = extra or {}
  self.state = {
    status = "empty",
    lines = {},
    plain_text = "",
    synced = false,
    estimated = false,
    provider = nil,
    score = nil,
    low_confidence = false,
    error = #errors > 0 and table.concat(errors, "; ") or nil,
    debug = debug or {},
    offset_ms = self.state.offset_ms or 0,
    variant = self.state.variant or 1,
    variant_count = self.state.variant_count or 1,
    duration_ms = info and info.duration_ms or 0,
    timeout = extra.timeout == true,
    provisional = false,
    searching = false,
  }
  local key = (info and info.uri or "") .. "#" .. tostring(self.state.variant)
  self.cache:set(key, util.copy(self.state))
  self:notify_update()
end

function Engine:lookup(pb, opts)
  opts = opts or {}
  local config = self.config

  if not pb or not pb.track then
    self.generation = self.generation + 1
    self:reset_state("nothing playing")
    self:notify_update()
    return
  end

  local track = pb.track
  local uri = util.str(track.uri)
  if uri == "" then
    self:reset_state("track has no uri")
    self:notify_update()
    return
  end

  if not config.source_enabled(uri) then
    self.generation = self.generation + 1
    self:reset_state("source not enabled")
    self.state.status = "disabled"
    self:notify_update()
    return
  end

  local info = metadata.parse(track)
  local variant, offset = self:load_preferences(info)
  local variant_count = math.max(1, math.min(#info.queries, config.max_queries or 4, 6))
  if variant > variant_count then
    variant = 1
  end

  local same_track = self.current_uri == uri
  if not same_track then
    self.generation = self.generation + 1
    self.current_uri = uri
    self.info = info
    self.state.offset_ms = offset
    self.state.variant = variant
    self.state.variant_count = variant_count
    self.state.lines = {}
    self.state.status = "idle"
  end
  self.info = info
  self.state.variant = variant
  self.state.variant_count = variant_count
  if not same_track then
    self.last_debug = {}
  end

  if not info.is_music and not opts.force then
    self.state.status = "not_music"
    self.state.error = info.reason
    self.state.debug = info.debug
    self:notify_update()
    return
  end

  local key = uri .. "#" .. tostring(variant)
  if opts.force then
    self.cache:remove(key)
  else
    local cached = self.cache:get(key)
    if cached then
      self.state = util.copy(cached)
      self.state.offset_ms = offset
      self.state.variant = variant
      self.state.variant_count = variant_count
      self:notify_update()
      return
    end
  end

  if self.state.status == "loading" and self.state.loading_key == key and not opts.force then
    return
  end

  self.generation = self.generation + 1
  local gen = self.generation
  self.state.status = "loading"
  self.state.loading_key = key
  self.state.offset_ms = offset
  self.state.variant = variant
  self.state.variant_count = variant_count
  self.state.debug = {}
  self.state.lines = {}
  self.state.provider = nil
  self.state.error = nil
  self:notify_update()

  local debug = {}
  for _, line in ipairs(info.debug or {}) do
    debug[#debug + 1] = line
  end
  debug[#debug + 1] = string.format(
    "variant %d/%d · duration %s · providers %s",
    variant,
    variant_count,
    util.fmt_ms(info.duration_ms),
    table.concat(config.providers, ",")
  )
  self.last_debug = debug

  -- Put the selected variant first, then the remaining queries as fallbacks.
  local queries = {}
  local count = #info.queries
  if count > 0 then
    for i = 0, count - 1 do
      local query = info.queries[((variant - 1 + i) % count) + 1]
      query.duration_ms = info.duration_ms
      query.video_id = info.video_id
      query.uri = info.uri
      query.is_curator = (query.artist ~= nil and query.artist == info.channel_artist and info.channel_curator) or false
      queries[#queries + 1] = query
    end
  end
  local query_limit = math.min(#queries, config.max_queries)

  local best_synced, best_plain, best_any = nil, nil, nil
  local errors = {}
  local finished = false
  local provisional_result = nil

  local function is_cancelled()
    return gen ~= self.generation or self.current_uri ~= uri
  end

  local function consider(result, query)
    local ok, scored = pcall(score.score, query, result, {})
    if not ok then
      self:debug("score error: " .. tostring(scored))
      return
    end
    result.score = scored
    result.effective = scored.total + (result.synced and 0.05 or 0)
    result.query_label = query.label
    if not best_any or result.effective > best_any.effective then
      best_any = result
    end
    if result.synced then
      if not best_synced or result.effective > best_synced.effective then
        best_synced = result
      end
    else
      if not best_plain or result.effective > best_plain.effective then
        best_plain = result
      end
    end
  end

  local function choose()
    if best_synced and best_synced.score.total >= 0.68 then
      if not best_plain or best_synced.effective >= best_plain.effective - 0.08 then
        return best_synced
      end
    end
    if best_plain and best_plain.score.total >= 0.68 then
      return best_plain
    end
    if best_synced then
      return best_synced
    end
    if best_any and best_any.score.total >= 0.55 then
      return best_any
    end
    return nil
  end

  --- Show the first usable answer immediately while the other providers are
  --- still racing. If a synced answer arrives later, apply_result upgrades it.
  local function apply_provisional()
    if finished or is_cancelled() or not best_any then
      return
    end
    if best_any.score.total < 0.62 then
      return
    end
    if provisional_result and best_any.effective <= provisional_result.effective + 0.01 then
      return
    end
    provisional_result = best_any
    debug[#debug + 1] = "provisional: " .. score.summary(best_any)
    self:apply_result(best_any, info, debug, { provisional = true, searching = true })
  end

  local function finish(extra)
    if finished or is_cancelled() then
      return
    end
    finished = true
    local chosen = choose()
    if chosen then
      debug[#debug + 1] = "selected: " .. score.summary(chosen)
      if chosen.url then
        debug[#debug + 1] = "source: " .. chosen.url
      end
      self:apply_result(chosen, info, debug, {
        timeout = extra and extra.timeout == true,
        provisional = false,
        searching = false,
      })
    else
      debug[#debug + 1] = "no acceptable match"
      self:finish_empty(info, debug, errors, extra)
    end
  end

  local function run_query(index)
    if finished or is_cancelled() then
      return
    end
    if index > query_limit then
      finish()
      return
    end

    local query = queries[index]
    debug[#debug + 1] = string.format(
      "query %d/%d [%s]: %s — %s",
      index,
      query_limit,
      query.label or "?",
      query.title,
      query.artist ~= "" and query.artist or "(title only)"
    )

    local pending = #self.provider_list
    local loop_done = false
    local query_finished = false

    local function maybe_query_done()
      if query_finished or finished or is_cancelled() then
        return
      end
      if not loop_done or pending > 0 then
        return
      end
      query_finished = true
      if best_synced and best_synced.score.total >= 0.78 then
        finish()
        return
      end
      if best_plain and best_plain.score.total >= 0.85 then
        finish()
        return
      end
      if index < query_limit then
        run_query(index + 1)
      else
        finish()
      end
    end

    for _, provider in ipairs(self.provider_list) do
      if finished or is_cancelled() then
        break
      end

      local ctx = {
        http = self.http,
        config = config,
        max_body_bytes = config.max_body_bytes,
        debug = debug,
        is_cancelled = is_cancelled,
        video_id = info.video_id,
        duration_ms = info.duration_ms,
      }
      local completed = false
      self:debug("provider " .. provider.name .. " for query " .. index)

      local function done_cb(results, provider_errors)
        if completed then
          return
        end
        completed = true
        pending = pending - 1

        if not finished and not is_cancelled() then
          for _, message in ipairs(provider_errors or {}) do
            errors[#errors + 1] = message
            debug[#debug + 1] = "  ! " .. message
          end
          for _, result in ipairs(results or {}) do
            consider(result, query)
            debug[#debug + 1] = string.format(
              "  · %s: %s — %s · %.0f%%%s",
              result.provider,
              result.title,
              result.artist ~= "" and result.artist or "?",
              (result.score and result.score.total or 0) * 100,
              result.synced and " · synced" or ""
            )
          end
          if best_synced and best_synced.score.total >= 0.78 then
            finish()
            return
          end
          apply_provisional()
        end

        maybe_query_done()
      end

      local ok, search_err = pcall(provider.search, query, ctx, done_cb)
      if not ok and not completed then
        done_cb({}, { provider.name .. ": " .. tostring(search_err) })
      end
    end

    loop_done = true
    maybe_query_done()
  end

  spotatui.set_timeout(config.timeout_ms, function()
    if finished or gen ~= self.generation then
      return
    end
    debug[#debug + 1] = "lookup timed out"
    finish({ timeout = true })
  end)

  run_query(1)
end

function Engine:refresh(pb)
  if self.info then
    self.state.variant = 1
    self:save_variant(self.info, 1)
    for variant = 1, math.max(1, self.state.variant_count or 1) do
      self.cache:remove((self.info.uri or "") .. "#" .. tostring(variant))
    end
  end
  self:lookup(pb, { force = true })
end

function Engine:next_variant(pb)
  if not self.info or #self.info.queries == 0 then
    return
  end
  local count = math.max(1, math.min(#self.info.queries, self.config.max_queries or 4, 6))
  local next_variant = (self.state.variant or 1) % count + 1
  self.state.variant = next_variant
  self:save_variant(self.info, next_variant)
  local key = (self.info.uri or "") .. "#" .. tostring(next_variant)
  self.cache:remove(key)
  self:lookup(pb, { force = true })
  local message = i18n.fmt("match_changed", next_variant, count)
  if self.on_message then
    self.on_message(message, 3)
  else
    spotatui.notify(message, 3)
  end
end

function Engine:set_offset_absolute(value)
  if not self.info then
    return
  end
  local offset = util.clamp(math.floor(tonumber(value) or 0), -30000, 30000)
  self.state.offset_ms = offset
  self:save_offset(self.info, offset)
  self:notify_update()
  return offset
end

function Engine:set_offset(delta)
  if not self.info then
    return
  end
  return self:set_offset_absolute((self.state.offset_ms or 0) + delta)
end

function Engine:reset_offset()
  if not self.info then
    return
  end
  self.state.offset_ms = 0
  self:save_offset(self.info, 0)
  self:notify_update()
end

--- Automatic bias: the timer sees the playback snapshot from the previous
--- UI tick, so add one tick to the progress used for the highlight. A
--- user-provided SPOTATUI_LYRICS_BIAS_MS (>= 0) always wins.
function Engine:bias_ms()
  if self.config.bias_ms and self.config.bias_ms >= 0 then
    return self.config.bias_ms
  end
  local ok, cfg = pcall(spotatui.config)
  local tick = ok and cfg and cfg.behavior and tonumber(cfg.behavior.tick_rate_milliseconds) or 250
  return util.clamp(math.floor(tick), 0, 500)
end

function Engine:progress(pb)
  local progress = pb and tonumber(pb.progress_ms) or 0
  local bias = 0
  if pb and pb.is_playing ~= false then
    bias = self:bias_ms()
  end
  return math.max(0, progress + bias)
end

function Engine:current_index(pb)
  return lrc.line_index(self.state.lines, self:progress(pb), self.state.offset_ms or 0)
end

function Engine:seek_time(index, pb)
  local line = self.state.lines and self.state.lines[index]
  if not line then
    return nil
  end
  -- The offset is expressed in the same display space as the highlight, which
  -- includes the automatic bias while playing. Remove it to get a raw player
  -- position.
  local bias = 0
  if pb == nil or pb.is_playing ~= false then
    bias = self:bias_ms()
  end
  return math.max(0, line.time_ms + (self.state.offset_ms or 0) - bias)
end

function Engine:status_line()
  local state = self.state
  if state.status == "loading" then
    return i18n.t("loading")
  elseif state.status == "empty" then
    return i18n.t("empty")
  elseif state.status == "not_music" then
    return i18n.t("not_music")
  elseif state.status == "disabled" then
    return i18n.t("disabled")
  elseif state.status == "idle" then
    return i18n.t("idle")
  elseif state.status == "ready" then
    local provider = state.provider or "?"
    local kind = state.synced and i18n.t("synced")
      or (state.estimated and i18n.t("estimated") or i18n.t("text"))
    local confidence = state.low_confidence and (" · " .. i18n.t("low_confidence")) or ""
    return provider .. " · " .. kind .. confidence
  end
  return state.status or "?"
end

function Engine:debug_lines()
  local lines = {}
  lines[#lines + 1] = "spotatui-lyrics debug"
  lines[#lines + 1] = "screen: " .. tostring(spotatui.current_route and spotatui.current_route() or "?")
  lines[#lines + 1] = "status: " .. tostring(self.state.status)
  lines[#lines + 1] = "uri: " .. tostring(self.current_uri)
  lines[#lines + 1] = "provider: " .. tostring(self.state.provider)
  lines[#lines + 1] = "synced: " .. tostring(self.state.synced) .. " · estimated: " .. tostring(self.state.estimated)
  lines[#lines + 1] = "provisional: " .. tostring(self.state.provisional) .. " · searching: " .. tostring(self.state.searching)
  lines[#lines + 1] = "offset: " .. tostring(self.state.offset_ms) .. " ms"
  lines[#lines + 1] = "variant: " .. tostring(self.state.variant) .. "/" .. tostring(self.state.variant_count)
  lines[#lines + 1] = "lines: " .. tostring(#(self.state.lines or {}))
  if self.state.score then
    lines[#lines + 1] = string.format("score: %.0f%% (title %.0f%%, artist %.0f%%, duration %.0f%%)",
      self.state.score.total * 100,
      self.state.score.title * 100,
      self.state.score.artist * 100,
      self.state.score.duration * 100)
  end
  lines[#lines + 1] = ""
  for _, line in ipairs(self.last_debug or {}) do
    lines[#lines + 1] = line
  end
  return lines
end

return Engine
