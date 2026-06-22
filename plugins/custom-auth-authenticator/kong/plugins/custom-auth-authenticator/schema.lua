local typedefs = require "kong.db.schema.typedefs"

return {
  name = "custom-auth-authenticator",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          -- Redis connection (must match the custom-auth-token plugin)
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
              referenceable = true,
          } },
          { redis_database = {
              type = "integer",
              default = 0,
          } },
          { redis_timeout = {
              type = "integer",
              default = 2000,
          } },
          { key_prefix = {
              type = "string",
              default = "custom-auth",
          } },

          -- Upstream headers set on successful authentication
          { header_username = {
              type = "string",
              default = "X-Consumer-Username",
          } },
          { header_name = {
              type = "string",
              default = "X-Consumer-Name",
          } },
          { header_department = {
              type = "string",
              default = "X-Consumer-Department",
          } },
          { header_scope = {
              type = "string",
              default = "X-Consumer-Scope",
          } },

          -- Strip the Authorization header before proxying upstream
          { hide_credentials = {
              type = "boolean",
              default = true,
          } },
        },
    } },
  },
}
