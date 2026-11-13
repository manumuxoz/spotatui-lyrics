local lrc = require("ytlyrics.lrc")

test("lrc parses timestamps and text", function()
  local parsed = lrc.parse([[
[ar:Queen]
[ti:Bohemian Rhapsody]
[00:00.00]First synthetic line
[00:04.50]Second synthetic line
[00:09.12][00:20.00]Third synthetic line
]])
  assert_true(parsed.synced)
  assert_eq(#parsed.lines, 4)
  assert_eq(parsed.lines[1].time_ms, 0)
  assert_eq(parsed.lines[1].text, "First synthetic line")
  assert_eq(parsed.lines[2].time_ms, 4500)
  assert_eq(parsed.lines[3].time_ms, 9120)
  assert_eq(parsed.lines[4].time_ms, 20000)
end)

test("lrc handles minute:second:centisecond and enhanced word tags", function()
  local parsed = lrc.parse([[
[00:12:50]<00:12.50>Hello <00:13.00>world
]])
  assert_true(parsed.synced)
  assert_eq(parsed.lines[1].time_ms, 12500)
  assert_eq(parsed.lines[1].text, "Hello world")
end)

test("lrc applies the offset tag", function()
  local parsed = lrc.parse([[
[offset:+500]
[00:10.00]Line
]])
  assert_eq(parsed.lines[1].time_ms, 9500)
end)

test("lrc removes NetEase credit lines", function()
  local parsed = lrc.parse([[
[00:00.000] 作词 : Someone
[00:00.000] 作曲 : Someone Else
[00:01.000] Synthetic lyric
]])
  assert_true(parsed.synced)
  assert_eq(#parsed.lines, 1)
  assert_eq(parsed.lines[1].text, "Synthetic lyric")
end)

test("lrc treats a no-timestamp document as plain text", function()
  local parsed = lrc.parse("First line\n\nSecond line\n")
  assert_false(parsed.synced)
  assert_eq(#parsed.lines, 0)
  assert_eq(parsed.plain_text, "First line\nSecond line")
end)

test("lrc treats all-zero timestamps as plain text", function()
  local parsed = lrc.parse([[
[00:00.00]First
[00:00.00]Second
]])
  assert_false(parsed.synced)
  assert_eq(parsed.plain_text, "First\nSecond")
end)

test("lrc estimates a monotonic timeline for plain text", function()
  local parsed = lrc.parse_plain("Short\n[Chorus]\nA much longer line of lyrics here\nLast", 120000)
  assert_false(parsed.synced)
  assert_true(parsed.estimated)
  assert_eq(#parsed.lines, 4)
  assert_true(parsed.lines[2].is_header)
  for i = 2, #parsed.lines do
    assert_true(parsed.lines[i].time_ms >= parsed.lines[i - 1].time_ms)
  end
  assert_true(parsed.lines[#parsed.lines].time_ms < 120000)
end)

test("lrc finds the current line with an offset", function()
  local parsed = lrc.parse([[
[00:10.00]One
[00:20.00]Two
[00:30.00]Three
]])
  assert_eq(lrc.line_index(parsed.lines, 0, 0), 1)
  assert_eq(lrc.line_index(parsed.lines, 15000, 0), 1)
  assert_eq(lrc.line_index(parsed.lines, 25000, 0), 2)
  -- Positive offset means the lyric should appear later.
  assert_eq(lrc.line_index(parsed.lines, 25000, 6000), 1)
  assert_eq(lrc.line_index(parsed.lines, 25000, -6000), 3)
end)

test("lrc skips section headers when moving", function()
  local parsed = lrc.parse([[
[00:00.00][Verse]
[00:10.00]One
[00:20.00][Chorus]
[00:30.00]Two
]])
  assert_eq(lrc.next_index(parsed.lines, 1), 2)
  assert_eq(lrc.next_index(parsed.lines, 2), 4)
  assert_eq(lrc.prev_index(parsed.lines, 4), 2)
end)

test("lrc normalizes CRLF", function()
  local parsed = lrc.parse("[00:01.00]One\r\n[00:02.00]Two\r\n")
  assert_true(parsed.synced)
  assert_eq(#parsed.lines, 2)
  assert_eq(parsed.lines[2].text, "Two")
end)
