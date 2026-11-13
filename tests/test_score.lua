local score = require("ytlyrics.score")

test("score matches titles across accents and punctuation", function()
  assert_eq(score.title_score("Tití Me Preguntó", "Titi Me Pregunto"), 1)
  assert_true(score.title_score("Get Lucky", "Get Lucky (feat. Pharrell Williams)") >= 0.9)
  assert_true(score.title_score("Hello", "Hello") == 1)
  assert_true(score.title_score("Hello", "Hell") < 0.9)
end)

test("score does not reward a one-word partial title too much", function()
  local value = score.title_score("Happy", "Happy Together")
  assert_true(value < 0.95)
  assert_true(value > 0.5)
end)

test("score handles artist collaborations", function()
  assert_eq(score.artist_score("Daft Punk", "Daft Punk"), 1)
  assert_true(score.artist_score("Daft Punk", "Daft Punk, Pharrell Williams") >= 0.8)
  assert_true(score.artist_score("Earth, Wind & Fire", "Earth, Wind & Fire") == 1)
  assert_eq(score.artist_score("7clouds", "Daft Punk", true), 0.5)
  assert_eq(score.artist_score("", "Daft Punk"), 0.5)
end)

test("score duration bands", function()
  assert_eq(score.duration_score(200000, 200000), 1.0)
  assert_true(score.duration_score(200000, 204000) >= 0.9)
  assert_true(score.duration_score(200000, 230000) < 0.7)
  assert_true(score.duration_score(200000, 400000) < 0.2)
  assert_eq(score.duration_score(0, 200000), 0.5)
end)

test("score combines title, artist and duration", function()
  local query = { title = "Get Lucky", artist = "Daft Punk", duration_ms = 249000 }
  local good = { title = "Get Lucky", artist = "Daft Punk", duration_ms = 248000, synced = true }
  local bad = { title = "Get Lucky", artist = "Some Cover Band", duration_ms = 370000, synced = true }
  local good_score = score.score(query, good)
  local bad_score = score.score(query, bad)
  assert_true(good_score.total > 0.85)
  assert_true(bad_score.total < good_score.total)

  local album_version = { title = "Get Lucky", artist = "Daft Punk", duration_ms = 370000, synced = true }
  local album_score = score.score(query, album_version)
  assert_true(album_score.total < 0.7, "a 2-minute duration gap must not look confident")
end)

test("score ranks synced results above plain ties", function()
  local query = { title = "Song", artist = "Artist", duration_ms = 200000 }
  local results = {
    { title = "Song", artist = "Artist", duration_ms = 200000, synced = false },
    { title = "Song", artist = "Artist", duration_ms = 200000, synced = true },
  }
  score.rank(results, query)
  assert_true(results[1].synced)
  assert_true(results[2].synced == false)
end)

test("score summary is readable", function()
  local result = {
    provider = "LRCLIB",
    synced = true,
    title = "Song",
    artist = "Artist",
    duration_ms = 200000,
    score = { total = 0.9 },
  }
  assert_contains(score.summary(result), "LRCLIB")
  assert_contains(score.summary(result), "90%")
  assert_contains(score.summary(result), "synced")
end)
