local typedefs = require "kong.db.schema.typedefs"

return {
  name = "custom-auth-token",
  fields = {
    -- HTTP(S) only: this plugin terminates the request and returns directly.
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { redis_host = {
              type = "string",
              required = true,
              default = "redis",
          } },
          { redis_port = {
              type = "integer",
              default = 6379,
              between = { 0, 65535 },
          } },
          { redis_password = {
              type = "string",
              required = false,
              referenceable = true,   -- allows {vault://...} references
          } },
          { redis_database = {
              type = "integer",
              default = 0,
          } },
          { redis_timeout = {
              type = "integer",
              default = 2000,          -- ms (connect/send/read)
          } },
          { key_prefix = {
              type = "string",
              default = "custom-auth",
          } },
        },
    } },
  },
}
