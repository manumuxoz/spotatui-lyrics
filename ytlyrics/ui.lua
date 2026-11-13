-- Custom lyrics screen and key handling.

local util = require("ytlyrics.util")
local lrc = require("ytlyrics.lrc")
local i18n = require("ytlyrics.i18n")

local UI = {}
UI.__index = UI

local FOLLOW_RESUME_SECONDS = 8

function UI.new(opts)
  opts = opts or {}
  return setmetatable({
    config = opts.config,
    engine = opts.engine,
    opened = false,
    follow = true,
    browse = nil,
    last_interaction = 0,
    timer = nil,
    last_render_key = nil,
    warned_render_error = false,
  }, UI)
end

function UI:screen_route()
  return "plugin:" .. self.config.screen_name
end

function UI:is_open()
  return self.opened and spotatui.current_route() == self:screen_route()
end

function UI:theme()
  local ok, config = pcall(spotatui.config)
  if not ok or type(config) ~= "table" then
    return {}
  end
  return type(config.theme) == "table" and config.theme or {}
end

function UI:current_track()
  local pb = spotatui.playback()
  if pb and type(pb.track) == "table" then
    return pb
  end
  return nil
end

function UI:ensure_lookup(pb)
  if not pb or not pb.track then
    return
  end
  local uri = util.str(pb.track.uri)
  if uri == "" or not self.config.source_enabled(uri) then
    return
  end
  local state = self.engine.state
  if self.engine.current_uri ~= uri then
    self.engine:lookup(pb)
    return
  end
  if state.status == "idle" then
    self.engine:lookup(pb)
  end
end

function UI:register()
  local config = self.config
  spotatui.register_screen(config.screen_name, {
    title = i18n.t("screen_title"),
    on_key = function(key)
      self:on_key(key)
    end,
    on_open = function()
      self.opened = true
      self.follow = true
      self.browse = nil
      self.last_render_key = nil
      self:ensure_lookup(self:current_track())
      self:render(true)
    end,
    on_close = function()
      self.opened = false
      self.follow = true
      self.browse = nil
      self.last_render_key = nil
    end,
  })

  local prefix = config.command_prefix
  spotatui.register_command(prefix .. "open", function()
    self:open()
  end)
  spotatui.register_command(prefix .. "refresh", function()
    self:open({ refresh = true })
  end)
  spotatui.register_command(prefix .. "next_match", function()
    local pb = self:current_track()
    if not pb then
      spotatui.notify(i18n.t("no_track"), 3)
      return
    end
    if not self.opened then
      self:open()
    end
    self.engine:next_variant(pb)
  end)
  spotatui.register_command(prefix .. "offset_reset", function()
    self.engine:reset_offset()
    spotatui.notify(i18n.t("offset_reset"), 2)
    self:render(true)
  end)
  spotatui.register_command(prefix .. "debug", function()
    self:show_debug()
  end)
end

function UI:start()
  if self.timer then
    return
  end
  local interval = 150
  self.timer = spotatui.set_interval(interval, function()
    local ok, err = pcall(function()
      self:tick()
    end)
    if not ok and not self.warned_render_error then
      self.warned_render_error = true
      spotatui.log("[ytlyrics] tick error: " .. tostring(err))
    end
  end)
end

function UI:stop()
  if self.timer then
    spotatui.cancel_timer(self.timer)
    self.timer = nil
  end
end

function UI:open(opts)
  opts = opts or {}
  self.opened = true
  self.follow = true
  self.browse = nil
  self.last_render_key = nil
  spotatui.show_screen(self.config.screen_name)

  if opts.refresh then
    local pb = self:current_track()
    if pb then
      self.engine:refresh(pb)
    else
      spotatui.notify(i18n.t("no_track"), 3)
    end
  else
    self:ensure_lookup(self:current_track())
  end
  self:render(true)
end

function UI:tick()
  if not self:is_open() then
    return
  end
  if not self.follow and self.last_interaction > 0
    and os.time() - self.last_interaction >= FOLLOW_RESUME_SECONDS then
    self.follow = true
    self.browse = nil
    self.last_render_key = nil
  end
  local pb = self:current_track()
  self:ensure_lookup(pb)
  self:render(false)
end

function UI:on_playback()
  if self:is_open() then
    self:render(false)
  end
end

function UI:on_seek()
  if self:is_open() then
    self.last_render_key = nil
    self:render(true)
  end
end

function UI:on_track(pb)
  if pb and pb.track then
    if self.opened or self.config.prefetch then
      self.engine:lookup(pb)
    end
  else
    self.engine:reset_state(nil)
    if self:is_open() then
      self:render(true)
    end
  end
end

function UI:header_lines(pb)
  local lines = {}
  local track = pb and pb.track
  if not track then
    return {
      { text = i18n.t("nothing_playing"), bold = true },
      { text = i18n.t("keys_compact"), fg = "DarkGray", italic = true },
    }
  end

  local title = util.str(track.name)
  local artist = ""
  if type(track.artists) == "table" then
    artist = table.concat(track.artists, ", ")
  end

  lines[#lines + 1] = { text = "♪ " .. util.shorten(title, 120), bold = true }
  local parts = {}
  if artist ~= "" then
    parts[#parts + 1] = util.shorten(artist, 60)
  end
  parts[#parts + 1] = self.engine:status_line()
  parts[#parts + 1] = i18n.t("offset") .. " " .. string.format("%+d ms", self.engine.state.offset_ms or 0)
  parts[#parts + 1] = i18n.fmt(
    "variant",
    self.engine.state.variant or 1,
    self.engine.state.variant_count or 1
  )
  lines[#lines + 1] = { text = util.shorten(table.concat(parts, " · "), 160), fg = "DarkGray" }
  return lines
end

function UI:body_lines(pb)
  local state = self.engine.state
  if not pb or not pb.track then
    return { { text = i18n.t("nothing_playing"), italic = true } }
  end

  if not self.config.source_enabled(util.str(pb.track.uri)) then
    return { { text = i18n.t("disabled"), italic = true } }
  end

  if state.status == "loading" then
    return {
      { text = i18n.t("loading"), bold = true },
      { text = i18n.t("loading_hint"), fg = "DarkGray", italic = true },
    }
  elseif state.status == "empty" then
    return {
      { text = i18n.t("empty"), bold = true },
      { text = i18n.t("empty_hint"), fg = "DarkGray", italic = true },
    }
  elseif state.status == "not_music" then
    return {
      { text = i18n.t("not_music"), bold = true },
      { text = (state.error or "") .. (state.error and " · " or "") .. i18n.t("not_music_hint"),
        fg = "DarkGray", italic = true },
    }
  elseif state.status == "disabled" then
    return { { text = i18n.t("disabled"), italic = true } }
  elseif state.status == "idle" then
    return { { text = i18n.t("idle"), italic = true } }
  end

  local lines = state.lines or {}
  if #lines == 0 then
    return { { text = i18n.t("empty"), italic = true } }
  end

  local current = self.engine:current_index(pb)
  local selected = self.follow and current or self.browse
  selected = util.clamp(selected or 1, 1, #lines)
  if lines[selected] and lines[selected].is_header then
    selected = lrc.next_index(lines, selected) or selected
  end

  local context = self.config.context_lines
  local window = context * 2 + 1
  local first = util.clamp(selected - context, 1, math.max(1, #lines - window + 1))
  local last = math.min(#lines, first + window - 1)

  local theme = self:theme()
  local highlighted = theme.highlighted_lyrics or theme.active or "Green"
  local inactive = theme.inactive or "DarkGray"
  local normal = theme.text or "Reset"
  local browsed = theme.hovered or "Magenta"
  local progress = self.engine:progress(pb) - (state.offset_ms or 0)

  local out = {}
  for i = first, last do
    local line = lines[i]
    local text = "  " .. line.text
    if line.is_header then
      out[#out + 1] = { text = "  " .. line.text, fg = inactive, italic = true }
    elseif i == selected then
      local color = self.follow and highlighted or browsed
      out[#out + 1] = { text = "▸ " .. line.text, fg = color, bold = true }
    elseif line.time_ms <= progress then
      out[#out + 1] = { text = text, fg = inactive }
    else
      out[#out + 1] = { text = text, fg = normal }
    end
  end
  return out
end

function UI:progress_widget(pb)
  local duration = 0
  local progress = 0
  if pb and pb.track then
    duration = tonumber(pb.track.duration_ms) or 0
    progress = tonumber(pb.progress_ms) or 0
  end
  local ratio = duration > 0 and util.clamp(progress / duration, 0, 1) or 0
  local label = i18n.fmt(
    "progress",
    util.fmt_ms(progress),
    duration > 0 and util.fmt_ms(duration) or "--:--"
  )
  return {
    type = "gauge",
    ratio = ratio,
    label = label,
    height = 3,
  }
end

function UI:footer_lines()
  local state = self.engine.state
  local parts = {
    i18n.t("keys_compact"),
  }
  local meta = {}
  if state.provider then
    meta[#meta + 1] = state.provider
  end
  meta[#meta + 1] = i18n.t("match") .. " " .. tostring(state.variant or 1) .. "/" .. tostring(state.variant_count or 1)
  meta[#meta + 1] = self.follow and i18n.t("follow") or i18n.t("follow_paused")
  return {
    { text = table.concat(parts, " "), fg = "DarkGray", italic = true },
    { text = util.shorten(table.concat(meta, " · "), 150), fg = "DarkGray" },
  }
end

function UI:render(force)
  if not force and not self.opened then
    return
  end
  local pb = self:current_track()
  local state = self.engine.state
  local current = self.engine:current_index(pb)
  local selected = self.follow and current or self.browse
  local progress_second = pb and math.floor((tonumber(pb.progress_ms) or 0) / 1000) or 0
  local key = table.concat({
    tostring(pb and pb.track and pb.track.uri or ""),
    tostring(state.status),
    tostring(selected or ""),
    tostring(self.follow),
    tostring(state.offset_ms or 0),
    tostring(state.variant or 1),
    tostring(state.provider or ""),
    tostring(state.synced),
    tostring(state.estimated),
    tostring(state.low_confidence),
    tostring(#(state.lines or {})),
    tostring(progress_second),
    tostring(state.lines and state.lines[1] and state.lines[1].text or ""),
  }, "|")
  if not force and key == self.last_render_key then
    return
  end
  self.last_render_key = key

  local widgets = {
    { type = "paragraph", height = 2, scroll = false, lines = self:header_lines(pb) },
    { type = "paragraph", scroll = false, lines = self:body_lines(pb) },
    self:progress_widget(pb),
    { type = "paragraph", height = 2, scroll = false, lines = self:footer_lines() },
  }

  local ok, err = pcall(spotatui.set_screen, self.config.screen_name, widgets)
  if not ok then
    spotatui.log("[ytlyrics] set_screen failed: " .. tostring(err))
    if not self.warned_render_error then
      self.warned_render_error = true
      spotatui.notify("Lyrics screen error: " .. tostring(err), 6)
    end
  end
end

function UI:on_key(key)
  self.last_interaction = os.time()
  local pb = self:current_track()
  local state = self.engine.state
  local lines = state.lines or {}

  if key == "j" or key == "down" then
    if #lines == 0 then
      return
    end
    local current = self.engine:current_index(pb) or 1
    if self.follow then
      self.browse = current
      self.follow = false
    end
    self.browse = lrc.next_index(lines, self.browse or current)
    self:render(true)
  elseif key == "k" or key == "up" then
    if #lines == 0 then
      return
    end
    local current = self.engine:current_index(pb) or 1
    if self.follow then
      self.browse = current
      self.follow = false
    end
    self.browse = lrc.prev_index(lines, self.browse or current)
    self:render(true)
  elseif key == "f" then
    self.follow = true
    self.browse = nil
    self:render(true)
  elseif key == "s" then
    if #lines == 0 then
      spotatui.notify(i18n.t("empty"), 2)
      return
    end
    local selected = self.follow and (self.engine:current_index(pb) or 1) or (self.browse or 1)
    local seek_ms = self.engine:seek_time(selected)
    if seek_ms then
      spotatui.seek(math.floor(seek_ms))
      self.follow = true
      self.browse = nil
      self:render(true)
    end
  elseif key == "[" then
    self.engine:set_offset(-self.config.offset_step_ms)
    self:render(true)
  elseif key == "]" then
    self.engine:set_offset(self.config.offset_step_ms)
    self:render(true)
  elseif key == "{" then
    self.engine:set_offset(-1000)
    self:render(true)
  elseif key == "}" then
    self.engine:set_offset(1000)
    self:render(true)
  elseif key == "0" then
    self.engine:reset_offset()
    self:render(true)
  elseif key == "m" then
    if pb then
      self.follow = true
      self.browse = nil
      self.engine:next_variant(pb)
    end
  elseif key == "r" then
    if pb then
      self.follow = true
      self.browse = nil
      self.engine:refresh(pb)
    else
      spotatui.notify(i18n.t("no_track"), 2)
    end
  elseif key == "i" then
    self:show_debug()
  end
end

function UI:show_debug()
  local lines = self.engine:debug_lines()
  spotatui.popup(i18n.t("debug_title"), lines)
end

return UI
