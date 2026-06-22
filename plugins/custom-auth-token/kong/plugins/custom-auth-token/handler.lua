-- custom-auth-token
--
-- A small CRUD API (attached to a dummy Route) that issues and manages auth
-- tokens stored in Redis. The plugin terminates the request and responds
-- directly; it does not proxy to an upstream.
--
--   GET    /            -> list of { token, user_name }
--   GET    /<token>     -> full record
--   POST   /            -> create (token generated as UUID), returns record
--   PUT    /  | /<token>-> update existing record (token from body), 404 if absent
--   DELETE /<token>     -> delete record
--
-- Record shape (JSON):
--   { token, user_name, name, department, scope }
--     user_name  : string, no spaces
--     name       : string, spaces allowed   ("Taroh Yamada")
--     department : string, no spaces         ("sales-tokyo")
--     scope      : space-separated grants    ("inquiry application cancel order")

local redis      = require "resty.redis"
local cjson_safe = require "cjson.safe"
local array_mt   = require("cjson").array_mt
local uuid       = require("kong.tools.uuid").uuid

local kong   = kong
local ipairs = ipairs
local type   = type
local fmt    = string.format

local CustomAuthToken = {
  PRIORITY = 1000,
  VERSION  = "0.1.0",
}

local RECORD_FIELDS = { "user_name", "name", "department", "scope" }

-- ---------------------------------------------------------------------------
-- Redis helpers
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
  -- return the connection to the pool (10s idle timeout, pool size 100)
  local ok = red:set_keepalive(10000, 100)
  if not ok then
    pcall(function() red:close() end)
  end
end

local function token_key(conf, token)
  return conf.key_prefix .. ":token:" .. token
end

local function index_key(conf)
  return conf.key_prefix .. ":index"
end

-- Read a single record. Returns the record table, or nil if not found.
local function read_record(red, conf, token)
  local res, err = red:hgetall(token_key(conf, token))
  if not res then
    return nil, err
  end
  if #res == 0 then
    return nil          -- not found
  end

  local rec = { token = token }
  for i = 1, #res, 2 do
    rec[res[i]] = res[i + 1]
  end
  return rec
end

-- List all records as an array of { token, user_name }.
local function list_records(red, conf)
  local res, err = red:hgetall(index_key(conf))   -- field = token, value = user_name
  if not res then
    return nil, err
  end

  local out = setmetatable({}, array_mt)            -- always encode as a JSON array
  for i = 1, #res, 2 do
    out[#out + 1] = { token = res[i], user_name = res[i + 1] }
  end
  return out
end

-- Create or fully replace a record.
local function write_record(red, conf, token, rec)
  local key = token_key(conf, token)

  red:init_pipeline()
  red:del(key)                                      -- clear any stale fields
  red:hset(key,
           "user_name",  rec.user_name,
           "name",       rec.name,
           "department", rec.department,
           "scope",      rec.scope)
  red:hset(index_key(conf), token, rec.user_name)   -- maintain the listing index
  local results, err = red:commit_pipeline()
  if not results then
    return nil, err
  end
  return true
end

local function delete_record(red, conf, token)
  red:init_pipeline()
  red:del(token_key(conf, token))
  red:hdel(index_key(conf), token)
  local results, err = red:commit_pipeline()
  if not results then
    return nil, err
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Request helpers
-- ---------------------------------------------------------------------------

local function has_space(s)
  return s:find("%s") ~= nil
end

-- Validate the request body and return a normalized record (token excluded).
local function validate_record(body)
  if type(body) ~= "table" then
    return nil, { "request body must be a JSON object" }
  end

  local errs = {}
  for _, f in ipairs(RECORD_FIELDS) do
    local v = body[f]
    if v == nil or v == "" then
      errs[#errs + 1] = f .. " is required"
    elseif type(v) ~= "string" then
      errs[#errs + 1] = f .. " must be a string"
    end
  end

  if type(body.user_name) == "string" and has_space(body.user_name) then
    errs[#errs + 1] = "user_name must not contain spaces"
  end
  if type(body.department) == "string" and has_space(body.department) then
    errs[#errs + 1] = "department must not contain spaces"
  end

  if #errs > 0 then
    return nil, errs
  end

  return {
    user_name  = body.user_name,
    name       = body.name,
    department = body.department,
    scope      = body.scope,
  }
end

local function read_json_body()
  local raw = kong.request.get_raw_body()
  if not raw or raw == "" then
    return nil, "empty request body"
  end
  local decoded = cjson_safe.decode(raw)
  if decoded == nil then
    return nil, "invalid JSON body"
  end
  return decoded
end

-- Extract the trailing path segment (the token id) after the Route's matched
-- prefix path. Returns nil for the collection endpoint.
local function path_id()
  local path = kong.request.get_path() or "/"

  local best = ""
  local route = kong.router.get_route()
  if route and route.paths then
    for _, p in ipairs(route.paths) do
      -- only plain prefix paths (skip regex paths starting with "~")
      if p:sub(1, 1) ~= "~" and #p > #best and path:sub(1, #p) == p then
        best = p
      end
    end
  end

  local sub = path:sub(#best + 1)
  sub = sub:gsub("^/+", ""):gsub("/+$", "")
  if sub == "" then
    return nil
  end
  return sub
end

-- ---------------------------------------------------------------------------
-- Handlers per method
-- ---------------------------------------------------------------------------

local function handle_get(red, conf, id)
  if id then
    local rec, err = read_record(red, conf, id)
    if err then
      return 500, { message = "storage error", error = tostring(err) }
    end
    if not rec then
      return 404, { message = "token not found" }
    end
    return 200, rec
  end

  local list, err = list_records(red, conf)
  if err then
    return 500, { message = "storage error", error = tostring(err) }
  end
  return 200, list
end

local function handle_post(red, conf, id)
  if id then
    return 400, { message = "POST must target the collection (no token in path)" }
  end

  local body, berr = read_json_body()
  if not body then
    return 400, { message = berr }
  end

  local rec, verr = validate_record(body)
  if not rec then
    return 400, { message = "validation failed", errors = verr }
  end

  local token = uuid()
  local ok, werr = write_record(red, conf, token, rec)
  if not ok then
    return 500, { message = "storage error", error = tostring(werr) }
  end

  rec.token = token
  return 201, rec
end

local function handle_put(red, conf, id)
  local body, berr = read_json_body()
  if not body then
    return 400, { message = berr }
  end

  local token = body.token
  if id and token and id ~= token then
    return 400, { message = "token in path does not match token in body" }
  end
  token = token or id
  if not token or token == "" then
    return 400, { message = "token is required (in body or path)" }
  end

  local existing, eerr = read_record(red, conf, token)
  if eerr then
    return 500, { message = "storage error", error = tostring(eerr) }
  end
  if not existing then
    return 404, { message = "token not found" }
  end

  local rec, verr = validate_record(body)
  if not rec then
    return 400, { message = "validation failed", errors = verr }
  end

  local ok, werr = write_record(red, conf, token, rec)
  if not ok then
    return 500, { message = "storage error", error = tostring(werr) }
  end

  rec.token = token
  return 200, rec
end

local function handle_delete(red, conf, id)
  if not id then
    return 400, { message = "token is required in path: DELETE /<token>" }
  end

  local existing, eerr = read_record(red, conf, id)
  if eerr then
    return 500, { message = "storage error", error = tostring(eerr) }
  end
  if not existing then
    return 404, { message = "token not found" }
  end

  local ok, derr = delete_record(red, conf, id)
  if not ok then
    return 500, { message = "storage error", error = tostring(derr) }
  end
  return 204, nil
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

function CustomAuthToken:access(conf)
  local method = kong.request.get_method()

  if method ~= "GET" and method ~= "POST"
     and method ~= "PUT" and method ~= "DELETE" then
    return kong.response.exit(405, { message = "method not allowed" },
                              { ["Allow"] = "GET, POST, PUT, DELETE" })
  end

  local red, cerr = redis_connect(conf)
  if not red then
    kong.log.err(cerr)
    return kong.response.exit(502, { message = "storage backend unavailable" })
  end

  local id = path_id()

  local status, body
  if method == "GET" then
    status, body = handle_get(red, conf, id)
  elseif method == "POST" then
    status, body = handle_post(red, conf, id)
  elseif method == "PUT" then
    status, body = handle_put(red, conf, id)
  else -- DELETE
    status, body = handle_delete(red, conf, id)
  end

  redis_close(red)

  kong.log.debug(fmt("custom-auth-token %s id=%s -> %s", method, tostring(id), status))
  return kong.response.exit(status, body)
end

return CustomAuthToken
