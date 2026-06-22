-- custom-auth-authenticator
--
-- Authenticates a request by validating its Bearer token against the records
-- created by the custom-auth-token plugin (Redis: <key_prefix>:token:<token>).
--
--   * No token / malformed token / token not found in Redis -> 401
--   * Valid token -> set X-Consumer-* headers from the record and proxy upstream
--
-- Headers set on success (configurable):
--   X-Consumer-Username   <- user_name
--   X-Consumer-Name       <- name
--   X-Consumer-Department <- department
--   X-Consumer-Scope      <- scope

local redis = require "resty.redis"

local kong = kong

local CustomAuthAuthenticator = {
  PRIORITY = 1250,   -- run as an authentication plugin (before most access plugins)
  VERSION  = "0.1.0",
}

-- ---------------------------------------------------------------------------
-- Redis helpers (kept self-contained so the plugin can be uploaded on its own)
-- ---------------------------------------------------------------------------

local function redis_connect(conf)
  local red = redis:new()
  red:set_timeouts(conf.redis_timeout, conf.redis_timeout, conf.redis_timeout)

  local ok, err = red:connect(conf.redis_host, conf.redis_port)
  if not ok then
    return nil, "failed to connect to redis: " .. tostring(err)
  end

  if conf.redis_password and conf.redis_password ~= "" then
    local _, aerr = red:auth(conf.redis_password)
    if aerr then
      return nil, "redis auth failed: " .. tostring(aerr)
    end
  end

  if conf.redis_database and conf.redis_database > 0 then
    local _, serr = red:select(conf.redis_database)
    if serr then
      return nil, "redis select failed: " .. tostring(serr)
    end
  end

  return red
end

local function redis_close(red)
  if not red then
    return
  end
  local ok = red:set_keepalive(10000, 100)
  if not ok then
    pcall(function() red:close() end)
  end
end

-- Read a token record. Returns the record table, or nil if not found.
local function read_record(red, conf, token)
  local res, err = red:hgetall(conf.key_prefix .. ":token:" .. token)
  if not res then
    return nil, err
  end
  if #res == 0 then
    return nil          -- not found
  end

  local rec = {}
  for i = 1, #res, 2 do
    rec[res[i]] = res[i + 1]
  end
  return rec
end

-- ---------------------------------------------------------------------------
-- Request helpers
-- ---------------------------------------------------------------------------

local function unauthorized(message)
  return kong.response.exit(401, { message = message },
                            { ["WWW-Authenticate"] = 'Bearer realm="kong"' })
end

-- Extract the token from the "Authorization: Bearer <token>" header.
local function extract_bearer_token()
  local auth = kong.request.get_header("Authorization")
  if type(auth) ~= "string" then
    return nil
  end
  local token = auth:match("^%s*[Bb][Ee][Aa][Rr][Ee][Rr]%s+(.+)$")
  if not token then
    return nil
  end
  token = token:gsub("^%s+", ""):gsub("%s+$", "")
  if token == "" then
    return nil
  end
  return token
end

-- Set (or clear, to prevent client spoofing) an upstream header.
local function apply_header(name, value)
  if not name or name == "" then
    return
  end
  if value ~= nil and value ~= "" then
    kong.service.request.set_header(name, value)
  else
    kong.service.request.clear_header(name)
  end
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

function CustomAuthAuthenticator:access(conf)
  local token = extract_bearer_token()
  if not token then
    return unauthorized("missing or malformed Bearer token")
  end

  local red, cerr = redis_connect(conf)
  if not red then
    kong.log.err(cerr)
    return kong.response.exit(502, { message = "storage backend unavailable" })
  end

  local rec, rerr = read_record(red, conf, token)
  redis_close(red)

  if rerr then
    kong.log.err("redis read failed: ", rerr)
    return kong.response.exit(502, { message = "storage error" })
  end

  if not rec then
    return unauthorized("invalid token")
  end

  -- Authenticated: inject identity/scope headers (overwriting any client value).
  apply_header(conf.header_username,   rec.user_name)
  apply_header(conf.header_name,       rec.name)
  apply_header(conf.header_department, rec.department)
  apply_header(conf.header_scope,      rec.scope)

  if conf.hide_credentials then
    kong.service.request.clear_header("Authorization")
  end
end

return CustomAuthAuthenticator
