-- Small LRU cache for resolved lookups.
--
-- Lyrics are not written to disk: they are copyrighted text and the plugin
-- only needs them for the current session. Offsets and the chosen query
-- variant are the only values persisted, through spotatui.storage_*.

local M = {}

local Cache = {}
Cache.__index = Cache

function M.new(max_entries)
  return setmetatable({
    max = max_entries or 24,
    map = {},
    order = {},
  }, Cache)
end

function Cache:get(key)
  local entry = self.map[key]
  if not entry then
    return nil
  end
  for i, existing in ipairs(self.order) do
    if existing == key then
      table.remove(self.order, i)
      break
    end
  end
  self.order[#self.order + 1] = key
  return entry
end

function Cache:set(key, value)
  if not self.map[key] then
    self.order[#self.order + 1] = key
  end
  self.map[key] = value
  while #self.order > self.max do
    local oldest = table.remove(self.order, 1)
    self.map[oldest] = nil
  end
end

function Cache:remove(key)
  self.map[key] = nil
  for i, existing in ipairs(self.order) do
    if existing == key then
      table.remove(self.order, i)
      break
    end
  end
end

function Cache:clear()
  self.map = {}
  self.order = {}
end

return M
