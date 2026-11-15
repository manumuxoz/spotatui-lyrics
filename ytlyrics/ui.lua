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
    warmed = false,
    flash_message = nil,
    flash_until = 0,
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

function UI:behavior()
  local ok, config = pcall(spotatui.config)
  if not ok or type(config) ~= "table" then
    return {}
  end
  return type(config.behavior) == "table" and config.behavior or {}
end

function UI:current_track()
  local pb = spotatui.playback()
  if pb and type(pb.track) == "table" then
    return pb
  end
  return nil
end

function UI:flash(text, ttl)
  self.flash_message = text
  self.flash_until = os.time() + (ttl or 3)
  self.last_render_key = nil
  self:render(true)
end

function UI:message(text, ttl)
  if self:is_open() then
    self:flash(text, ttl)
  else
    spotatui.notify(text, ttl or 3)
  end
end

function UI:active_message()
  if self.flash_message and os.time() < self.flash_until then
    return self.flash_message
  end
  if self.flash_message then
    self.flash_message = nil
    self.flash_until = 0
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
      self.warmed = true
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
  spotatui.register_command(prefix .. "open_alt", function()
    self:open()
  end)
  spotatui.register_command(prefix .. "refresh", function()
    self:open({ refresh = true })
  end)
  spotatui.register_command(prefix .. "next_match", function()
    local pb = self:current_track()
    if not pb then
      self:message(i18n.t("no_track"), 3)
      return
    end
    if not self.opened then
      self:open()
    end
    self.engine:next_variant(pb)
  end)
  spotatui.register_command(prefix .. "offset_reset", function()
    self.engine:reset_offset()
    self:message(i18n.t("offset_reset"), 2)
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
      self:message(i18n.t("no_track"), 3)
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
  if self.flash_message and os.time() >= self.flash_until then
    self.flash_message = nil
    self.flash_until = 0
    self.last_render_key = nil
  end
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
    if self.opened or self.config.prefetch or (self.config.warm and self.warmed) then
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

  local behavior = self:behavior()
  local icon = "♪ "
  if pb.is_playing == false then
    icon = (behavior.paused_icon or "⏸") .. " "
  elseif behavior.playing_icon then
    icon = behavior.playing_icon .. " "
  end
  lines[#lines + 1] = { text = icon .. util.shorten(title, 120), bold = true }
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

--- A playbar-shaped progress line: the same ⣿/⣉ glyphs and colors as the
--- main playbar, implemented as a two-part row so the filled and empty halves
--- can have different theme colors. It adapts to the available width because
--- both halves are percentage-sized and their text is clipped by the renderer.
function UI:progress_widget(pb)
  local duration = 0
  local progress = 0
  if pb and pb.track then
    duration = tonumber(pb.track.duration_ms) or 0
    progress = tonumber(pb.progress_ms) or 0
  end
  local ratio = duration > 0 and util.clamp(progress / duration, 0, 1) or 0
  local end_label = duration > 0 and util.fmt_ms(duration) or "--:--"
  local remaining = duration > 0 and (" (-" .. util.fmt_ms(math.max(0, duration - progress)) .. ")") or ""
  local label = util.fmt_ms(progress) .. "/" .. end_label .. remaining

  local theme = self:theme()
  local filled_color = theme.playbar_progress or theme.active or "Green"
  local empty_color = theme.playbar_background or theme.inactive or "Reset"
  local text_color = theme.playbar_progress_text or theme.playbar_text or theme.text or "Reset"

  -- The main playbar shows "m:ss/m:ss (-m:ss)" to the left of a ⣿/⣉ line.
  local filled = util.clamp(math.floor(ratio * 75 + 0.5), 1, 74)
  local empty = 75 - filled
  return {
    type = "row",
    height = 1,
    children = {
      {
        type = "paragraph",
        width_percent = 25,
        lines = { { text = label .. " ", fg = text_color } },
      },
      {
        type = "paragraph",
        width_percent = filled,
        lines = { { text = string.rep("⣿", 200), fg = filled_color } },
      },
      {
        type = "paragraph",
        width_percent = empty,
        lines = { { text = string.rep("⣉", 200), fg = empty_color } },
      },
    },
  }
end

function UI:controls_line(pb)
  local theme = self:theme()
  local text = "p prev  ·  space play/pause  ·  n next  ·  < > seek"
  if not pb or not pb.track then
    text = ""
  end
  return {
    { text = text, fg = theme.playbar_text or theme.inactive or "DarkGray", italic = true },
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
  if state.searching then
    meta[#meta + 1] = i18n.t("searching_synced")
  end
  local message = self:active_message()
  local first = message and { text = message, fg = "Yellow", bold = true }
    or { text = table.concat(parts, " "), fg = "DarkGray", italic = true }
  return {
    first,
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
    tostring(state.provisional),
    tostring(state.searching),
    tostring(self:active_message() or ""),
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
    { type = "paragraph", height = 1, scroll = false, lines = self:controls_line(pb) },
    self:progress_widget(pb),
    { type = "paragraph", height = 2, scroll = false, lines = self:footer_lines() },
  }

  local ok, err = pcall(spotatui.set_screen, self.config.screen_name, widgets)
  if not ok then
    spotatui.log("[ytlyrics] set_screen failed: " .. tostring(err))
    if not self.warned_render_error then
      self.warned_render_error = true
      self:flash("Lyrics screen error: " .. tostring(err), 6)
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
      self:message(i18n.t("empty"), 2)
      return
    end
    local selected = self.follow and (self.engine:current_index(pb) or 1) or (self.browse or 1)
    local seek_ms = self.engine:seek_time(selected, pb)
    if seek_ms then
      spotatui.seek(math.floor(seek_ms))
      self.follow = true
      self.browse = nil
      self:render(true)
    end
  elseif key == "t" then
    self:calibrate()
  elseif key == "," then
    self.engine:set_offset(-self.config.offset_fine_ms)
    self:render(true)
  elseif key == "." then
    self.engine:set_offset(self.config.offset_fine_ms)
    self:render(true)
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
      self:message(i18n.t("no_track"), 2)
    end
  elseif key == "i" then
    self:show_debug()
  end
end

function UI:calibrate()
  local pb = self:current_track()
  local lines = self.engine.state.lines or {}
  if not pb or #lines == 0 then
    self:message(i18n.t("empty"), 2)
    return
  end
  local selected = self.follow and (self.engine:current_index(pb) or 1) or (self.browse or 1)
  if lines[selected] and lines[selected].is_header then
    selected = lrc.next_index(lines, selected) or selected
  end
  local line = lines[selected]
  if not line then
    return
  end
  local display_progress = self.engine:progress(pb)
  -- Align the line with the highlight's display space (progress + bias while playing).
  local offset = self.engine:set_offset_absolute(display_progress - line.time_ms)
  self:message(i18n.fmt("offset_calibrated", offset or 0), 4)
  self:render(true)
end

function UI:show_debug()
  local lines = self.engine:debug_lines()
  spotatui.popup(i18n.t("debug_title"), lines)
end

return UI
