-- spotatui-lyrics: synced lyrics for YouTube (and every other source) with
-- metadata repair and provider fallbacks.
--
-- Entry point. The actual work lives in ytlyrics/ modules so the code can be
-- tested with plain Lua 5.4 outside spotatui.

spotatui.require_api(6)

local config = require("ytlyrics.config")
local http = require("ytlyrics.http")
local Engine = require("ytlyrics.engine")
local UI = require("ytlyrics.ui")

local engine = Engine.new({
  config = config,
  http = http,
})

local ui = UI.new({
  config = config,
  engine = engine,
})

engine.on_update = function()
  ui:render(false)
end

engine.on_message = function(message, ttl)
  ui:message(message, ttl)
end

ui:register()

local function guard(name, fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      spotatui.log("[ytlyrics] " .. name .. " error: " .. tostring(err))
    end
  end
end

spotatui.on("start", guard("start", function()
  ui:start()
  local pb = spotatui.playback()
  if pb and pb.track then
    ui:on_track(pb)
  end
  spotatui.log(string.format(
    "[ytlyrics] ready · providers=%s · sources=%s",
    table.concat(config.providers, ","),
    table.concat(config.sources, ",")
  ))
end))

spotatui.on("track_change", guard("track_change", function(pb)
  ui:on_track(pb)
end))

spotatui.on("playback_state_change", guard("playback_state_change", function()
  ui:on_playback()
end))

spotatui.on("seek", guard("seek", function()
  ui:on_seek()
end))

spotatui.on("quit", guard("quit", function()
  ui:stop()
end))

return {
  engine = engine,
  ui = ui,
  config = config,
}
