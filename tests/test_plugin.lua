local Harness = require("tests.harness")

local TRACK = {
  uri = "youtube:GUXO0000001",
  name = "Guxo - Si El Mundo Fuera Perfecto",
  artists = { "Guxo" },
  duration_ms = 213000,
}

local GENIUS_PAGE = [[
<html><body>
<div class="Lyrics__Container" data-lyrics-container="true">
[Intro]<br>Synthetic line one<br>Synthetic line one<br>Synthetic line three<br>
[Estribillo]<br>Synthetic line two<br>Synthetic line four
</div>
</body></html>
]]

local function setup()
  local h = Harness.new()
  h.json_handler = function(body)
    if body == "NETEASE_EMPTY" then
      return { result = { songs = {} } }
    elseif body == "GENIUS_SEARCH" then
      return {
        response = {
          sections = {
            {
              type = "song",
              hits = {
                {
                  result = {
                    _type = "song",
                    id = 14573112,
                    title = "Si El Mundo Fuera Perfecto",
                    full_title = "Si El Mundo Fuera Perfecto by Guxo",
                    url = "https://genius.com/Guxo-si-el-mundo-fuera-perfecto-lyrics",
                    primary_artist = { name = "Guxo" },
                  },
                },
              },
            },
          },
        },
      }
    end
    error("unexpected JSON body: " .. tostring(body))
  end

  h:route_http("genius.com/api/search/multi", { status = 200, body = "GENIUS_SEARCH" })
  h:route_http("/api/get", { status = 404, body = "" })
  h:route_http(function(method, url)
    return url:find("lrclib.net/api/search", 1, true) ~= nil
  end, { status = 404, body = "" })
  h:route_http("api/cloudsearch/pc", { status = 200, body = "NETEASE_EMPTY" })
  h:route_http("genius.com/Guxo-si-el-mundo-fuera-perfecto-lyrics", {
    status = 200,
    body = GENIUS_PAGE,
  })

  h:set_playback(TRACK, 0, true)
  h:load_plugin(".")
  package.loaded["ytlyrics.i18n"].lang = "en"
  h:emit("start")
  return h
end

test("plugin opens a screen and renders Genius lyrics", function()
  local h = setup()
  h:run_command("ytlyrics_open")
  local text = h:screen_text("ytlyrics")
  assert_contains(text, "Guxo")
  assert_contains(text, "Synthetic line one")
  assert_contains(text, "Genius")
  assert_contains(text, "0:00")
  assert_true(h.render_count > 0)
end)

test("plugin loads lyrics lazily only when the screen opens", function()
  local h = setup()
  assert_eq(#h.http_requests, 0)
  h:run_command("ytlyrics_open")
  assert_true(#h.http_requests > 0)
end)

test("plugin seeks to the selected lyric line", function()
  local h = setup()
  h:run_command("ytlyrics_open")
  -- The screen's j key pauses follow; s seeks from the browsed line.
  local spec = h.screens["ytlyrics"]
  spec.on_key("j")
  spec.on_key("s")
  assert_true(#h.seeks > 0)
  assert_true(h.seeks[1] > 0)
end)

test("plugin adjusts and persists the offset", function()
  local h = setup()
  h:run_command("ytlyrics_open")
  local spec = h.screens["ytlyrics"]
  spec.on_key("]")
  assert_eq(h.storage["offset:GUXO0000001"], 250)
  spec.on_key("[")
  assert_eq(h.storage["offset:GUXO0000001"], 0)
end)

test("plugin cycles match variants and stores the choice", function()
  local h = setup()
  h:run_command("ytlyrics_open")
  local spec = h.screens["ytlyrics"]
  spec.on_key("m")
  assert_eq(h.storage["variant:GUXO0000001"], 2)
  assert_true(#h.notifications > 0)
end)

test("plugin opens the debug popup", function()
  local h = setup()
  h:run_command("ytlyrics_open")
  h:run_command("ytlyrics_debug")
  assert_eq(#h.popups, 1)
  assert_eq(h.popups[1].title, "Lyrics debug")
  local text = table.concat(h.popups[1].lines, "\n")
  assert_contains(text, "provider:")
  assert_contains(text, "Genius")
end)

test("plugin renders a loading state during a deferred lookup", function()
  local h = setup()
  -- Make the Genius page wait; the screen should show loading until the
  -- response arrives.
  for _, route in ipairs(h.http_routes) do
    if route.pattern == "genius.com/Guxo-si-el-mundo-fuera-perfecto-lyrics" then
      route.response = "defer"
    end
  end
  h:run_command("ytlyrics_open")
  local text = h:screen_text("ytlyrics")
  assert_contains(text, "Looking up lyrics")
  assert_true(#h.pending > 0)
  h:respond(1, { status = 200, body = GENIUS_PAGE })
  text = h:screen_text("ytlyrics")
  assert_contains(text, "Synthetic line one")
end)
