local metadata = require("ytlyrics.metadata")

local function query_by_label(info, label)
  for _, query in ipairs(info.queries) do
    if query.label == label then
      return query
    end
  end
  return nil
end

local function parse(title, channel, duration)
  return metadata.parse({
    name = title,
    artists = { channel },
    uri = "youtube:abc12345678",
    duration_ms = duration or 240000,
  })
end

test("metadata parses the usual Artist - Song shape", function()
  local info = parse(
    "Daft Punk - Get Lucky (Official Audio) ft. Pharrell Williams, Nile Rodgers",
    "Daft Punk",
    249000
  )
  assert_eq(info.title, "Get Lucky")
  assert_eq(info.artist, "Daft Punk")
  assert_eq(info.parsed_artist, "Daft Punk")
  assert_eq(info.channel_artist, "Daft Punk")
  assert_false(info.channel_curator)
  assert_eq(info.queries[1].title, "Get Lucky")
  assert_eq(info.queries[1].artist, "Daft Punk")
  assert_eq(info.featured[1], "Pharrell Williams, Nile Rodgers")
end)

test("metadata ignores curator channels when the title has the artist", function()
  local info = parse(
    "Daft Punk - Get Lucky (Lyrics) ft. Pharrell Williams, Nile Rodgers",
    "7clouds",
    246000
  )
  assert_eq(info.title, "Get Lucky")
  assert_eq(info.artist, "Daft Punk")
  assert_true(info.channel_curator)
  for _, query in ipairs(info.queries) do
    if query.label ~= "raw metadata" then
      assert_true(query.artist ~= "7clouds", "curator channel leaked into query " .. query.label)
    end
  end
end)

test("metadata keeps Latin accents", function()
  local info = parse("Bad Bunny - Tití Me Preguntó (Official Video)", "Bad Bunny", 291000)
  assert_eq(info.title, "Tití Me Preguntó")
  assert_eq(info.artist, "Bad Bunny")
  local title_only = query_by_label(info, "title only")
  assert_eq(title_only.title, "Tití Me Preguntó")
  assert_eq(title_only.artist, "")
end)

test("metadata works without a dash", function()
  local info = parse("Si El Mundo Fuera Perfecto", "Guxo", 213000)
  assert_eq(info.title, "Si El Mundo Fuera Perfecto")
  assert_eq(info.artist, "Guxo")
  assert_eq(info.queries[1].artist, "Guxo")
  local title_only = query_by_label(info, "title only")
  assert_eq(title_only.artist, "")
end)

test("metadata strips remaster and HD tags", function()
  local info = parse("The Beatles - Don't Let Me Down (Remastered 2009)", "The Beatles", 200000)
  assert_eq(info.title, "Don't Let Me Down")
  assert_eq(info.artist, "The Beatles")

  local hd = parse("Earth, Wind & Fire - September (Official HD Video)", "Earth, Wind & Fire", 215000)
  assert_eq(hd.title, "September")
  assert_eq(hd.artist, "Earth, Wind & Fire")
  assert_eq(#hd.artists, 1)
  assert_eq(hd.artists[1], "Earth, Wind & Fire")
end)

test("metadata handles quoted K-pop titles", function()
  local info = parse("BTS (방탄소년단) 'Dynamite' Official MV", "HYBE LABELS", 200000)
  assert_eq(info.title, "Dynamite")
  assert_eq(info.parsed_artist, "BTS (방탄소년단)")
  assert_eq(query_by_label(info, "title + artist variant").artist, "BTS")
  assert_true(info.channel_curator)

  local twice = parse("TWICE 'FANCY' M/V", "TWICE", 220000)
  assert_eq(twice.title, "FANCY")
  assert_eq(twice.artist, "TWICE")
end)

test("metadata keeps song - artist as a fallback", function()
  local info = parse("Despacito - Luis Fonsi ft. Daddy Yankee", "Some Channel", 282000)
  assert_eq(info.title, "Luis Fonsi")
  assert_eq(info.artist, "Despacito")
  local swapped = query_by_label(info, "swapped artist/title")
  assert_eq(swapped.title, "Despacito")
  assert_eq(swapped.artist, "Luis Fonsi")
end)

test("metadata treats a one-word song as a title, not a credit", function()
  local info = parse("Audio - LSD", "LSD", 200000)
  assert_eq(info.title, "Audio")
  assert_eq(info.artist, "LSD")
end)

test("metadata leaves titles such as Video Killed the Radio Star alone", function()
  local info = parse("Video Killed the Radio Star", "The Buggles", 240000)
  assert_eq(info.title, "Video Killed the Radio Star")
  assert_eq(info.artist, "The Buggles")
end)

test("metadata marks talks and long videos as non-music", function()
  local long = parse("How to install Arch Linux (Full Guide)", "Some Tech", 1200000)
  assert_false(long.is_music)

  local podcast = parse("Episode 42 - The History of Synths", "A Podcast", 600000)
  assert_false(podcast.is_music)
end)

test("metadata drops album suffixes after a pipe", function()
  local info = parse(
    "Daft Punk - Get Lucky (Official Audio) | Random Access Memories",
    "Daft Punk",
    249000
  )
  assert_eq(info.title, "Get Lucky")
  assert_eq(info.artist, "Daft Punk")
end)

test("metadata routes original and clean titles through queries", function()
  local info = parse("Adele - Hello (Live at the NRJ Awards)", "Adele", 300000)
  assert_eq(info.title, "Hello")
  assert_eq(info.artist, "Adele")
  assert_eq(info.versions[1], "live")
  assert_eq(info.queries[1].title, "Hello")
end)

test("metadata strips a version tag after a dash", function()
  local info = parse("Adele - Hello - Live", "Adele", 300000)
  assert_eq(info.title, "Hello")
  assert_eq(info.artist, "Adele")
  assert_eq(info.versions[1], "live")
end)
