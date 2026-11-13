-- Minimal spotatui Lua API harness for tests.
--
-- It implements the parts of API v6 the plugin uses, records HTTP requests,
-- and renders custom screens into plain text so assertions can read them.

local Harness = {}
Harness.__index = Harness

local next_id = 0
local function id()
  next_id = next_id + 1
  return next_id
end

function Harness.new()
  local self = setmetatable({
    route = "home",
    playback_state = nil,
    storage = {},
    commands = {},
    screens = {},
    events = {},
    timers = {},
    timer_order = {},
    http_routes = {},
    http_requests = {},
    pending = {},
    logs = {},
    notifications = {},
    popups = {},
    seeks = {},
    render_count = 0,
    last_widgets = {},
    now_ms = 0,
    json_handler = function()
      error("no json_handler configured")
    end,
    config_state = {
      theme = {
        highlighted_lyrics = "Green",
        active = "Green",
        inactive = "DarkGray",
        text = "Reset",
        hovered = "Magenta",
        error_text = "Red",
      },
      behavior = {
        tick_rate_milliseconds = 250,
        language = "en",
      },
    },
  }, Harness)

  local h = self
  self.spotatui = {
    api_version = 6,
    require_api = function(version)
      if version > 6 then
        error("requires spotatui scripting API v" .. version)
      end
    end,
    on = function(event, callback)
      self:register_event(event, callback)
    end,
    log = function(message)
      h.logs[#h.logs + 1] = tostring(message)
    end,
    notify = function(message, ttl)
      h.notifications[#h.notifications + 1] = { message = tostring(message), ttl = ttl }
    end,
    json_decode = function(text)
      return h.json_handler(text)
    end,
    json_encode = function()
      return "{}"
    end,
    http_get = function(url, callback)
      h:http_call("GET", url, nil, nil, callback)
    end,
    http_post = function(url, body, headers, callback)
      h:http_call("POST", url, body, headers, callback)
    end,
    register_command = function(name, callback)
      h.commands[name] = callback
    end,
    register_screen = function(name, spec)
      h.screens[name] = spec
    end,
    set_screen = function(name, widgets)
      if not h.screens[name] then
        error("unknown screen " .. name)
      end
      h.last_widgets[name] = widgets
      h.render_count = h.render_count + 1
    end,
    show_screen = function(name)
      if not h.screens[name] then
        error("unknown screen " .. name)
      end
      h.route = "plugin:" .. name
      if h.screens[name].on_open then
        h.screens[name].on_open()
      end
    end,
    close_screen = function(name)
      if h.route == "plugin:" .. name then
        h.route = "home"
        if h.screens[name].on_close then
          h.screens[name].on_close()
        end
      end
    end,
    current_route = function()
      return h.route
    end,
    playback = function()
      return h.playback_state
    end,
    current_track = function()
      return h.playback_state and h.playback_state.track or nil
    end,
    config = function()
      return h.config_state
    end,
    storage_get = function(key)
      return h.storage[key]
    end,
    storage_set = function(key, value)
      h.storage[key] = value
    end,
    storage_remove = function(key)
      h.storage[key] = nil
    end,
    storage_keys = function()
      local keys = {}
      for key in pairs(h.storage) do
        keys[#keys + 1] = key
      end
      table.sort(keys)
      return keys
    end,
    set_timeout = function(ms, callback)
      local timer_id = id()
      h.timers[timer_id] = { id = timer_id, at = h.now_ms + ms, every = nil, callback = callback }
      h.timer_order[#h.timer_order + 1] = timer_id
      return timer_id
    end,
    set_interval = function(ms, callback)
      local timer_id = id()
      h.timers[timer_id] = { id = timer_id, at = h.now_ms + ms, every = ms, callback = callback }
      h.timer_order[#h.timer_order + 1] = timer_id
      return timer_id
    end,
    cancel_timer = function(timer_id)
      h.timers[timer_id] = nil
    end,
    popup = function(title, lines)
      h.popups[#h.popups + 1] = { title = title, lines = lines }
    end,
    set_playbar = function() end,
    set_theme = function() end,
    navigate = function(target)
      h.route = target
    end,
    back = function()
      h.route = "home"
    end,
    seek = function(ms)
      h.seeks[#h.seeks + 1] = ms
    end,
    play = function() end,
    pause = function() end,
    next = function() end,
    previous = function() end,
    set_volume = function() end,
    get_lyrics = function(callback)
      callback({ status = "not_found", lines = {} }, nil)
    end,
  }
  _G.spotatui = self.spotatui
  return self
end

function Harness:route_http(pattern, response)
  self.http_routes[#self.http_routes + 1] = {
    pattern = pattern,
    response = response,
  }
end

function Harness:http_call(method, url, body, headers, callback)
  self.http_requests[#self.http_requests + 1] = {
    method = method,
    url = url,
    body = body,
    headers = headers,
  }

  for _, route in ipairs(self.http_routes) do
    local matched = false
    if type(route.pattern) == "function" then
      matched = route.pattern(method, url, body, headers)
    else
      matched = url:find(route.pattern, 1, true) ~= nil
    end
    if matched then
      local response = route.response
      if type(response) == "function" then
        response = response(method, url, body, headers)
      end
      if response == "defer" then
        self.pending[#self.pending + 1] = { callback = callback, method = method, url = url }
        return
      end
      if response then
        callback(response, nil)
        return
      end
      callback(nil, "no response")
      return
    end
  end

  self.pending[#self.pending + 1] = { callback = callback, method = method, url = url }
end

function Harness:respond(index, response, err)
  index = index or 1
  local pending = self.pending[index]
  if not pending then
    error("no pending HTTP request at " .. index)
  end
  table.remove(self.pending, index)
  pending.callback(response, err)
end

function Harness:set_playback(track, progress_ms, is_playing)
  self.playback_state = {
    track = track,
    progress_ms = progress_ms or 0,
    is_playing = is_playing ~= false,
    volume_percent = 100,
    shuffle = false,
    ["repeat"] = "off",
  }
  return self.playback_state
end

function Harness:emit(event, ...)
  local handlers = self.events[event] or {}
  for _, callback in ipairs(handlers) do
    callback(...)
  end
end

function Harness:run_command(name)
  local callback = self.commands[name]
  if not callback then
    error("unknown command " .. name)
  end
  callback()
end

function Harness:pressure_timers()
  -- Fire every timer once in creation order without advancing wall time.
  local ids = {}
  for timer_id in pairs(self.timers) do
    ids[#ids + 1] = timer_id
  end
  table.sort(ids)
  for _, timer_id in ipairs(ids) do
    local timer = self.timers[timer_id]
    if timer then
      timer.callback()
    end
  end
end

function Harness:advance(ms)
  local target = self.now_ms + ms
  local guard = 0
  while true do
    guard = guard + 1
    if guard > 10000 then
      error("timer advance loop")
    end
    local next_timer = nil
    for timer_id, timer in pairs(self.timers) do
      if timer.at <= target and (not next_timer or timer.at < next_timer.at) then
        next_timer = timer
      end
    end
    if not next_timer then
      break
    end
    self.now_ms = next_timer.at
    if next_timer.every then
      next_timer.at = next_timer.at + next_timer.every
    else
      self.timers[next_timer.id] = nil
    end
    next_timer.callback()
  end
  self.now_ms = target
end

function Harness:screen_text(name)
  name = name or "ytlyrics"
  local widgets = self.last_widgets[name]
  if not widgets then
    return ""
  end
  local out = {}
  local function walk(widget)
    if type(widget) ~= "table" then
      return
    end
    if widget.type == "paragraph" then
      for _, line in ipairs(widget.lines or {}) do
        if type(line) == "table" then
          out[#out + 1] = tostring(line.text or "")
        else
          out[#out + 1] = tostring(line)
        end
      end
    elseif widget.type == "list" then
      for _, line in ipairs(widget.items or {}) do
        out[#out + 1] = tostring(line)
      end
    elseif widget.type == "gauge" then
      out[#out + 1] = tostring(widget.label or "")
    elseif widget.children then
      for _, child in ipairs(widget.children) do
        walk(child)
      end
    end
  end
  for _, widget in ipairs(widgets) do
    walk(widget)
  end
  return table.concat(out, "\n")
end

function Harness:load_plugin(root)
  root = root or "."
  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
  for name in pairs(package.loaded) do
    if name == "main" or name:match("^ytlyrics") then
      package.loaded[name] = nil
    end
  end
  local chunk = assert(loadfile(root .. "/main.lua"))
  self.plugin = chunk()
  return self.plugin
end

function Harness:register_event(event, callback)
  self.events[event] = self.events[event] or {}
  self.events[event][#self.events[event] + 1] = callback
end

-- The plugin uses spotatui.on; wire it to the harness after creation.
function Harness:install_event_api()
  self.spotatui.on = function(event, callback)
    self:register_event(event, callback)
  end
end

return Harness
