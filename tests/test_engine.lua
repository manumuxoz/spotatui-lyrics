local Harness = require("tests.harness")
local Engine = require("ytlyrics.engine")

local TRACK = {
  uri = "youtube:GUXO0000001",
  name = "Guxo - Si El Mundo Fuera Perfecto",
  artists = { "Guxo" },
  duration_ms = 213000,
}

local function make_config()
  return {
    providers = { "lrclib" },
    sources = { "youtube" },
    source_enabled = function(uri)
      return uri:match("^youtube:") ~= nil
    end,
    max_queries = 3,
    max_body_bytes = 1024 * 1024,
    timeout_ms = 5000,
    estimate = true,
    bias_ms = 120,
    debug = false,
    context_lines = 6,
    offset_step_ms = 250,
  }
end

local function track(overrides)
  local t = {}
  for key, value in pairs(TRACK) do
    t[key] = value
  end
  for key, value in pairs(overrides or {}) do
    t[key] = value
  end
  return t
end

test("engine selects a synced result and caches it", function()
  local h = Harness.new()
  h:set_playback(track(), 1000, true)
  local engine = Engine.new({ config = make_config(), http = require("ytlyrics.http") })
  local calls = 0
  engine.provider_list = {
    {
      name = "Fake",
      id = "fake",
      search = function(query, ctx, done)
        calls = calls + 1
        done({
          {
            provider = "Fake",
            provider_id = "fake",
            title = query.title,
            artist = query.artist,
            duration_ms = 213000,
            synced = true,
            lines = { { time_ms = 10000, text = "La primera línea" }, { time_ms = 20000, text = "La segunda" } },
          },
        }, {})
      end,
    },
  }
  engine.on_update = function() end

  engine:lookup(h.playback_state)
  assert_eq(engine.state.status, "ready")
  assert_true(engine.state.synced)
  assert_eq(#engine.state.lines, 2)
  assert_eq(calls, 1)

  engine:lookup(h.playback_state)
  assert_eq(calls, 1, "cached lookup must not hit the provider again")
  assert_eq(engine.state.lines[1].text, "La primera línea")
end)

test("engine estimates a timeline for plain lyrics", function()
  local h = Harness.new()
  h:set_playback(track(), 0, true)
  local engine = Engine.new({ config = make_config(), http = require("ytlyrics.http") })
  engine.provider_list = {
    {
      name = "Fake",
      search = function(query, ctx, done)
        done({
          {
            provider = "Fake",
            title = query.title,
            artist = query.artist,
            duration_ms = 213000,
            synced = false,
            plain_text = "Line one\nLine two\nLine three",
          },
        }, {})
      end,
    },
  }
  engine:lookup(h.playback_state)
  assert_eq(engine.state.status, "ready")
  assert_false(engine.state.synced)
  assert_true(engine.state.estimated)
  assert_eq(#engine.state.lines, 3)
  assert_true(engine.state.lines[3].time_ms > engine.state.lines[1].time_ms)
end)

test("engine cycles query variants and persists the choice", function()
  local h = Harness.new()
  h:set_playback(track(), 0, true)
  local engine = Engine.new({ config = make_config(), http = require("ytlyrics.http") })
  local seen = {}
  engine.provider_list = {
    {
      name = "Fake",
      search = function(query, ctx, done)
        seen[#seen + 1] = query.title .. "|" .. query.artist
        done({}, {})
      end,
    },
  }
  engine:lookup(h.playback_state)
  assert_eq(engine.state.variant, 1)
  local first_title = seen[1]

  engine:next_variant(h.playback_state)
  assert_eq(engine.state.variant, 2)
  assert_true(seen[#seen] ~= first_title)
  assert_eq(h.storage["variant:GUXO0000001"], 2)
end)

test("engine applies and persists a manual offset", function()
  local h = Harness.new()
  h:set_playback(track(), 0, true)
  local engine = Engine.new({ config = make_config(), http = require("ytlyrics.http") })
  engine.provider_list = {
    {
      name = "Fake",
      search = function(query, ctx, done)
        done({
          {
            provider = "Fake",
            title = query.title,
            artist = query.artist,
            duration_ms = 213000,
            synced = true,
            lines = { { time_ms = 10000, text = "One" } },
          },
        }, {})
      end,
    },
  }
  engine:lookup(h.playback_state)
  assert_eq(engine.state.offset_ms, 0)
  engine:set_offset(500)
  assert_eq(engine.state.offset_ms, 500)
  assert_eq(h.storage["offset:GUXO0000001"], 500)
  engine:reset_offset()
  assert_eq(engine.state.offset_ms, 0)
  assert_eq(h.storage["offset:GUXO0000001"], 0)
end)

test("engine ignores callbacks from a previous track", function()
  local h = Harness.new()
  h:set_playback(track(), 0, true)
  local engine = Engine.new({ config = make_config(), http = require("ytlyrics.http") })
  local pending_done = nil
  engine.provider_list = {
    {
      name = "Fake",
      search = function(query, ctx, done)
        pending_done = done
      end,
    },
  }
  engine:lookup(h.playback_state)
  assert_eq(engine.state.status, "loading")

  h:set_playback(track({ uri = "youtube:OTHER000001", name = "Other - Song" }), 0, true)
  engine:lookup(h.playback_state)
  assert_eq(engine.state.status, "loading")

  pending_done({
    {
      provider = "Fake",
      title = "Si El Mundo Fuera Perfecto",
      artist = "Guxo",
      duration_ms = 213000,
      synced = true,
      lines = { { time_ms = 1, text = "stale" } },
    },
  }, {})

  assert_eq(engine.state.status, "loading")
  assert_eq(#engine.state.lines, 0)
end)

test("engine times out without a provider answer", function()
  local h = Harness.new()
  h:set_playback(track(), 0, true)
  local engine = Engine.new({ config = make_config(), http = require("ytlyrics.http") })
  engine.provider_list = {
    {
      name = "Fake",
      search = function() end,
    },
  }
  engine:lookup(h.playback_state)
  assert_eq(engine.state.status, "loading")
  h:advance(5000)
  assert_eq(engine.state.status, "empty")
  assert_true(engine.state.timeout)
end)

test("engine skips non-music tracks unless forced", function()
  local h = Harness.new()
  h:set_playback(track({ name = "How to install Arch Linux (Full Guide)", duration_ms = 1200000 }), 0, true)
  local engine = Engine.new({ config = make_config(), http = require("ytlyrics.http") })
  local calls = 0
  engine.provider_list = {
    {
      name = "Fake",
      search = function(query, ctx, done)
        calls = calls + 1
        done({}, {})
      end,
    },
  }
  engine:lookup(h.playback_state)
  assert_eq(engine.state.status, "not_music")
  assert_eq(calls, 0)
end)

test("engine debug lines include the query and score", function()
  local h = Harness.new()
  h:set_playback(track(), 0, true)
  local engine = Engine.new({ config = make_config(), http = require("ytlyrics.http") })
  engine.provider_list = {
    {
      name = "Fake",
      search = function(query, ctx, done)
        done({
          {
            provider = "Fake",
            title = query.title,
            artist = query.artist,
            duration_ms = 213000,
            synced = true,
            lines = { { time_ms = 10000, text = "One" } },
          },
        }, {})
      end,
    },
  }
  engine:lookup(h.playback_state)
  local text = table.concat(engine:debug_lines(), "\n")
  assert_contains(text, "query 1/3")
  assert_contains(text, "selected:")
  assert_contains(text, "Fake")
end)

test("engine survives a provider that throws synchronously", function()
  local h = Harness.new()
  h:set_playback(track(), 0, true)
  local engine = Engine.new({ config = make_config(), http = require("ytlyrics.http") })
  engine.provider_list = {
    {
      name = "Crash",
      search = function()
        error("provider boom")
      end,
    },
    {
      name = "Fake",
      search = function(query, ctx, done)
        done({
          {
            provider = "Fake",
            title = query.title,
            artist = query.artist,
            duration_ms = 213000,
            synced = true,
            lines = { { time_ms = 1000, text = "One" } },
          },
        }, {})
      end,
    },
  }
  engine:lookup(h.playback_state)
  assert_eq(engine.state.status, "ready")
  assert_eq(engine.state.provider, "Fake")
  assert_true(#engine.state.lines > 0)
end)
