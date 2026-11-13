-- Thin wrapper around spotatui's asynchronous HTTP API.
--
-- spotatui.http_get has no header argument, but its shared reqwest client sends
-- a "spotatui/<version>" User-Agent. For providers that reject that UA, the
-- plugin can issue a POST with X-HTTP-Method-Override: GET and a browser UA.

local util = require("ytlyrics.util")

local M = {}

M.urlencode = util.urlencode

local function normalize_response(resp)
  if type(resp) ~= "table" then
    return nil, "empty HTTP response"
  end
  return {
    status = tonumber(resp.status) or 0,
    ok = resp.ok == true,
    body = type(resp.body) == "string" and resp.body or "",
  }, nil
end

function M.get(url, callback)
  spotatui.http_get(url, function(resp, err)
    if err then
      callback(nil, tostring(err))
      return
    end
    local normalized, response_err = normalize_response(resp)
    if not normalized then
      callback(nil, response_err)
      return
    end
    callback(normalized, nil)
  end)
end

function M.post(url, body, headers, callback)
  body = body or ""
  headers = headers or {}
  spotatui.http_post(url, body, headers, function(resp, err)
    if err then
      callback(nil, tostring(err))
      return
    end
    local normalized, response_err = normalize_response(resp)
    if not normalized then
      callback(nil, response_err)
      return
    end
    callback(normalized, nil)
  end)
end

--- GET semantics through http_post, which does allow headers.
function M.get_override(url, headers, callback)
  headers = util.copy(headers or {})
  headers["X-HTTP-Method-Override"] = "GET"
  M.post(url, "", headers, callback)
end

function M.is_success(resp)
  return resp ~= nil and resp.status >= 200 and resp.status < 300 and resp.body ~= ""
end

function M.decode_json(resp, max_bytes)
  if not resp then
    return nil, "no response"
  end
  if resp.status < 200 or resp.status >= 300 then
    return nil, "HTTP " .. tostring(resp.status)
  end
  if resp.body == "" then
    return nil, "empty body"
  end
  if max_bytes and #resp.body > max_bytes then
    return nil, string.format("response too large (%d bytes)", #resp.body)
  end
  local ok, decoded = pcall(spotatui.json_decode, resp.body)
  if not ok then
    return nil, "invalid JSON: " .. tostring(decoded)
  end
  if type(decoded) ~= "table" then
    return nil, "JSON root is not an object"
  end
  return decoded, nil
end

--- Fetch and decode JSON in one step.
function M.get_json(url, max_bytes, callback)
  M.get(url, function(resp, err)
    if err then
      callback(nil, err, resp)
      return
    end
    local decoded, decode_err = M.decode_json(resp, max_bytes)
    callback(decoded, decode_err, resp)
  end)
end

function M.post_json(url, body, headers, max_bytes, callback)
  M.post(url, body, headers, function(resp, err)
    if err then
      callback(nil, err, resp)
      return
    end
    local decoded, decode_err = M.decode_json(resp, max_bytes)
    callback(decoded, decode_err, resp)
  end)
end

return M
