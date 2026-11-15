local Harness = require("tests.harness")
local lrclib = require("ytlyrics.providers.lrclib")
local netease = require("ytlyrics.providers.netease")
local genius = require("ytlyrics.providers.genius")
local ytmusic = require("ytlyrics.providers.youtube_music")

local function make_ctx(h)
  return {
    http = require("ytlyrics.http"),
    config = { genius_browser_fallback = true },
    max_body_bytes = 1024 * 1024,
    debug = {},
    is_cancelled = function()
      return false
    end,
  }
end

test("lrclib exact lookup returns synced lines", function()
  local h = Harness.new()
  h.json_handler = function(body)
    assert_eq(body, "LRCLIB_GET")
    return {
      id = 986804,
      trackName = "Get Lucky",
      artistName = "Daft Punk",
      albumName = "Random Access Memories",
      duration = 249,
      syncedLyrics = "[00:01.00]Synthetic lyric one\n[00:02.00]Synthetic lyric two",
    }
  end
  h:route_http("/api/get", { status = 200, body = "LRCLIB_GET" })

  local results, errors
  lrclib.search({ title = "Get Lucky", artist = "Daft Punk", duration_ms = 249000 }, make_ctx(h), function(r, e)
    results, errors = r, e
  end)
  assert_eq(#errors, 0)
  assert_eq(#results, 1)
  assert_true(results[1].synced)
  assert_eq(results[1].provider, "LRCLIB")
  assert_eq(results[1].lines[1].text, "Synthetic lyric one")
end)

test("lrclib falls back to fuzzy search", function()
  local h = Harness.new()
  h.json_handler = function(body)
    if body == "LRCLIB_SEARCH" then
      return {
        {
          id = 1,
          trackName = "Tití Me Preguntó",
          artistName = "Bad Bunny",
          duration = 291,
          syncedLyrics = "[00:10.00]Synthetic lyric one\n[00:15.00]Synthetic lyric two",
        },
      }
    end
    error("unexpected body " .. body)
  end
  h:route_http("/api/get", { status = 404, body = "" })
  h:route_http("/api/search", { status = 200, body = "LRCLIB_SEARCH" })

  local results
  lrclib.search({ title = "Tití Me Preguntó", artist = "Bad Bunny", duration_ms = 291000 }, make_ctx(h), function(r)
    results = r
  end)
  assert_eq(#results, 1)
  assert_eq(results[1].title, "Tití Me Preguntó")
  assert_eq(h.http_requests[2].url:find("/api/search", 1, true) ~= nil, true)
end)

test("netease search and lyric return synced lines", function()
  local h = Harness.new()
  h.json_handler = function(body)
    if body == "NETEASE_SEARCH" then
      return {
        result = {
          songs = {
            { id = 1944936667, name = "Tití Me Preguntó", ar = { { name = "Bad Bunny" } }, dt = 243716 },
          },
        },
      }
    elseif body == "NETEASE_LYRIC" then
      return { lrc = { lyric = "[00:10.00]Synthetic lyric one\n[00:15.00]Synthetic lyric two" } }
    end
    error("unexpected body " .. body)
  end
  h:route_http("api/cloudsearch/pc", { status = 200, body = "NETEASE_SEARCH" })
  h:route_http("api/song/lyric", { status = 200, body = "NETEASE_LYRIC" })

  local results
  netease.search({ title = "Tití Me Preguntó", artist = "Bad Bunny", duration_ms = 243000 }, make_ctx(h), function(r)
    results = r
  end)
  assert_eq(#results, 1)
  assert_true(results[1].synced)
  assert_eq(results[1].title, "Tití Me Preguntó")
  assert_eq(results[1].lines[1].time_ms, 10000)
end)

test("genius search and page extraction return plain lyrics", function()
  local h = Harness.new()
  h.json_handler = function(body)
    assert_eq(body, "GENIUS_SEARCH")
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
  h:route_http("genius.com/api/search/multi", { status = 200, body = "GENIUS_SEARCH" })
  h:route_http("genius.com/Guxo-si-el-mundo-fuera-perfecto-lyrics", {
    status = 200,
    body = '<div data-lyrics-container="true">[Intro]<br>Synthetic line one<br>Synthetic line two</div>',
  })

  local results
  genius.search({ title = "Si El Mundo Fuera Perfecto", artist = "Guxo", duration_ms = 213000 }, make_ctx(h), function(r)
    results = r
  end)
  assert_eq(#results, 1)
  assert_false(results[1].synced)
  assert_contains(results[1].plain_text, "Synthetic line one")
  assert_contains(results[1].plain_text, "Synthetic line two")
end)

test("genius retries with the browser POST override when blocked", function()
  local h = Harness.new()
  h.json_handler = function(body)
    if body == "GENIUS_BLOCKED" then
      error("blocked")
    end
    return {
      response = {
        sections = {
          {
            hits = {
              {
                result = {
                  _type = "song",
                  title = "Song",
                  url = "https://genius.com/Artist-song-lyrics",
                  primary_artist = { name = "Artist" },
                },
              },
            },
          },
        },
      },
    }
  end
  h:route_http(function(method, url)
    return method == "GET" and url:find("genius.com/api/search/multi", 1, true) ~= nil
  end, { status = 403, body = "GENIUS_BLOCKED" })
  h:route_http(function(method, url, body, headers)
    return method == "POST" and headers and headers["X-HTTP-Method-Override"] == "GET"
      and url:find("genius.com/api/search/multi", 1, true) ~= nil
  end, { status = 200, body = "GENIUS_OK" })
  h:route_http("genius.com/Artist-song-lyrics", {
    status = 200,
    body = '<div data-lyrics-container="true">Line one<br>Line two</div>',
  })

  local results, errors
  genius.search({ title = "Song", artist = "Artist", duration_ms = 200000 }, make_ctx(h), function(r, e)
    results, errors = r, e
  end)
  assert_eq(#errors, 0)
  assert_eq(#results, 1)
  assert_contains(results[1].plain_text, "Line one")
  local used_override = false
  for _, request in ipairs(h.http_requests) do
    if request.method == "POST" and request.headers and request.headers["X-HTTP-Method-Override"] == "GET" then
      used_override = true
    end
  end
  assert_true(used_override)
end)

test("youtube music resolves a direct video and returns cue ranges", function()
  local h = Harness.new()
  h.json_handler = function(body)
    if body == "YTM_NEXT" then
      return {
        contents = {
          singleColumnMusicWatchNextResultsRenderer = {
            tabbedRenderer = {
              watchNextTabbedResultsRenderer = {
                tabs = {
                  {
                    tabRenderer = {
                      endpoint = {
                        browseEndpoint = {
                          browseId = "MPLYt_TEST",
                          browseEndpointContextSupportedConfigs = {
                            browseEndpointContextMusicConfig = {
                              pageType = "MUSIC_PAGE_TYPE_TRACK_LYRICS",
                            },
                          },
                        },
                      },
                    },
                  },
                },
              },
            },
          },
        },
      }
    elseif body == "YTM_BROWSE" then
      return {
        contents = {
          elementRenderer = {
            newElement = {
              type = {
                componentType = {
                  model = {
                    timedLyricsModel = {
                      lyricsData = {
                        timedLyricsData = {
                          { lyricLine = "Synthetic timed one", cueRange = { startTimeMilliseconds = "1000" } },
                          { lyricLine = "Synthetic timed two", cueRange = { startTimeMilliseconds = "2500" } },
                        },
                      },
                    },
                  },
                },
              },
            },
          },
        },
      }
    end
    error("unexpected body " .. body)
  end
  h:route_http("music.youtube.com/youtubei/v1/next", { status = 200, body = "YTM_NEXT" })
  h:route_http("music.youtube.com/youtubei/v1/browse", { status = 200, body = "YTM_BROWSE" })

  local results, errors
  ytmusic.search({
    video_id = "VID123",
    title = "Song",
    artist = "Artist",
    duration_ms = 200000,
  }, make_ctx(h), function(r, e) results, errors = r, e end)

  assert_eq(#errors, 0)
  assert_eq(#results, 1)
  assert_true(results[1].synced)
  assert_eq(results[1].lines[1].time_ms, 1000)
  assert_eq(results[1].lines[2].text, "Synthetic timed two")
end)

test("youtube music degrades to plain text without cue ranges", function()
  local h = Harness.new()
  h.json_handler = function(body)
    if body == "YTM_NEXT" then
      return {
        contents = {
          singleColumnMusicWatchNextResultsRenderer = {
            tabbedRenderer = {
              watchNextTabbedResultsRenderer = {
                tabs = { { tabRenderer = { endpoint = { browseEndpoint = { browseId = "MPLYt_TEST" } } } } },
              },
            },
          },
        },
      }
    elseif body == "YTM_BROWSE" then
      return {
        contents = {
          elementRenderer = {
            newElement = {
              type = {
                componentType = {
                  model = {
                    timedLyricsModel = {
                      lyricsData = {
                        timedLyricsData = {
                          { lyricLine = "Synthetic plain one" },
                          { lyricLine = "Synthetic plain two" },
                        },
                      },
                    },
                  },
                },
              },
            },
          },
        },
      }
    elseif body == "YTM_SEARCH_EMPTY" then
      return {}
    end
    error("unexpected body " .. body)
  end
  h:route_http("music.youtube.com/youtubei/v1/next", { status = 200, body = "YTM_NEXT" })
  h:route_http("music.youtube.com/youtubei/v1/browse", { status = 200, body = "YTM_BROWSE" })
  h:route_http("music.youtube.com/youtubei/v1/search", { status = 200, body = "YTM_SEARCH_EMPTY" })

  local results
  ytmusic.search({ video_id = "VID123", title = "Song", artist = "Artist", duration_ms = 200000 }, make_ctx(h), function(r)
    results = r
  end)
  assert_eq(#results, 1)
  assert_false(results[1].synced)
  assert_contains(results[1].plain_text, "Synthetic plain one")
end)

test("youtube music searches for an art track when the exact video has only text", function()
  local h = Harness.new()
  h.json_handler = function(body)
    if body == "YTM_NEXT_DIRECT" then
      return {
        contents = { singleColumnMusicWatchNextResultsRenderer = { tabbedRenderer = {
          watchNextTabbedResultsRenderer = { tabs = { { tabRenderer = { endpoint = { browseEndpoint = {
            browseId = "MPLYt_DIRECT",
            browseEndpointContextSupportedConfigs = { browseEndpointContextMusicConfig = {
              pageType = "MUSIC_PAGE_TYPE_TRACK_LYRICS",
            } },
          } } } } } },
        } } },
      }
    elseif body == "YTM_BROWSE_PLAIN" then
      return { contents = { elementRenderer = { newElement = { type = { componentType = { model = {
        timedLyricsModel = { lyricsData = { timedLyricsData = {
          { lyricLine = "Plain one" }, { lyricLine = "Plain two" },
        } } },
      } } } } } } }
    elseif body == "YTM_SEARCH" then
      return { contents = { sectionListRenderer = { contents = {
        { musicShelfRenderer = { contents = {
          { musicResponsiveListItemRenderer = {
            playlistItemData = { videoId = "ART456" },
            flexColumns = {
              { musicResponsiveListItemFlexColumnRenderer = { text = { runs = { { text = "Song" } } } } },
              { musicResponsiveListItemFlexColumnRenderer = { text = { runs = { { text = "Artist" } } } } },
            },
            fixedColumns = {
              { musicResponsiveListItemFixedColumnRenderer = { text = { runs = { { text = "3:20" } } } } },
            },
          } },
        } } },
      } } } }
    elseif body == "YTM_NEXT_ART" then
      return { contents = { singleColumnMusicWatchNextResultsRenderer = { tabbedRenderer = {
        watchNextTabbedResultsRenderer = { tabs = { { tabRenderer = { endpoint = { browseEndpoint = {
          browseId = "MPLYt_ART",
          browseEndpointContextSupportedConfigs = { browseEndpointContextMusicConfig = {
            pageType = "MUSIC_PAGE_TYPE_TRACK_LYRICS",
          } },
        } } } } } },
      } } } }
    elseif body == "YTM_BROWSE_SYNCED" then
      return { contents = { elementRenderer = { newElement = { type = { componentType = { model = {
        timedLyricsModel = { lyricsData = { timedLyricsData = {
          { lyricLine = "Synced one", cueRange = { startTimeMilliseconds = "1000" } },
          { lyricLine = "Synced two", cueRange = { startTimeMilliseconds = "2000" } },
        } } },
      } } } } } } }
    end
    error("unexpected body " .. body)
  end

  h:route_http(function(_, _, body) return body and body:find('"videoId":"VID123"', 1, true) ~= nil end,
    { status = 200, body = "YTM_NEXT_DIRECT" })
  h:route_http(function(_, _, body) return body and body:find('"browseId":"MPLYt_DIRECT"', 1, true) ~= nil end,
    { status = 200, body = "YTM_BROWSE_PLAIN" })
  h:route_http("music.youtube.com/youtubei/v1/search", { status = 200, body = "YTM_SEARCH" })
  h:route_http(function(_, _, body) return body and body:find('"videoId":"ART456"', 1, true) ~= nil end,
    { status = 200, body = "YTM_NEXT_ART" })
  h:route_http(function(_, _, body) return body and body:find('"browseId":"MPLYt_ART"', 1, true) ~= nil end,
    { status = 200, body = "YTM_BROWSE_SYNCED" })

  local results
  ytmusic.search({ video_id = "VID123", title = "Song", artist = "Artist", duration_ms = 200000 }, make_ctx(h), function(r)
    results = r
  end)
  local synced = 0
  for _, result in ipairs(results or {}) do
    if result.synced then
      synced = synced + 1
      assert_eq(result.lines[1].time_ms, 1000)
    end
  end
  assert_true(synced >= 1, "the art-track fallback must produce a synced result")
end)

test("lrcmux compat endpoint returns synced lyrics", function()
  local h = Harness.new()
  h.json_handler = function(body)
    assert_eq(body, "LRCMUX_COMPAT")
    return {
      trackName = "Synthetic Song",
      artistName = "Synthetic Artist",
      duration = 200,
      syncedLyrics = "[00:01.00]Synthetic lrcmux one\n[00:02.00]Synthetic lrcmux two",
    }
  end
  h:route_http("api.lrcmux.dev/compat/lrclib/api/get", { status = 200, body = "LRCMUX_COMPAT" })
  local results
  require("ytlyrics.providers.lrcmux").search({
    title = "Synthetic Song",
    artist = "Synthetic Artist",
    duration_ms = 200000,
  }, make_ctx(h), function(r) results = r end)
  assert_eq(#results, 1)
  assert_true(results[1].synced)
  assert_eq(results[1].lines[1].time_ms, 1000)
end)

test("lrcmux native endpoint falls back to structured lines", function()
  local h = Harness.new()
  h.json_handler = function(body)
    assert_eq(body, "LRCMUX_NATIVE")
    return {
      track = { title = "Synthetic Song", artist = "Synthetic Artist", duration = 200 },
      lines = {
        { text = "Synthetic native one", start = 1000 },
        { text = "Synthetic native two", start = 2500 },
      },
    }
  end
  h:route_http("api.lrcmux.dev/compat/lrclib/api/get", { status = 404, body = "" })
  h:route_http("api.lrcmux.dev/get?", { status = 200, body = "LRCMUX_NATIVE" })
  local results
  require("ytlyrics.providers.lrcmux").search({
    title = "Synthetic Song",
    artist = "Synthetic Artist",
    duration_ms = 200000,
  }, make_ctx(h), function(r) results = r end)
  assert_eq(#results, 1)
  assert_true(results[1].synced)
  assert_eq(results[1].lines[2].time_ms, 2500)
end)
