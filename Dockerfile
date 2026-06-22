# Custom Kong Gateway (data plane) image with the auth plugins baked in.
#
# The plugin Lua files are copied into Kong's default Lua package path
# (/usr/local/share/lua/5.1/kong/plugins/<name>), so no KONG_LUA_PACKAGE_PATH
# override is needed. Enable them with KONG_PLUGINS.
#
# Build:
#   docker build --build-arg KONG_IMAGE=kong/kong-gateway:3.14 -t kong-custom-auth:local .
# or via compose:
#   docker compose build

ARG KONG_IMAGE=kong/kong-gateway:3.14
FROM ${KONG_IMAGE}

# COPY runs as root regardless of the base image's runtime user.
USER root

COPY plugins/custom-auth-token/kong/plugins/custom-auth-token \
     /usr/local/share/lua/5.1/kong/plugins/custom-auth-token
COPY plugins/custom-auth-authenticator/kong/plugins/custom-auth-authenticator \
     /usr/local/share/lua/5.1/kong/plugins/custom-auth-authenticator

# Make sure the kong runtime user can read the plugin files.
RUN chmod -R a+rX /usr/local/share/lua/5.1/kong/plugins/custom-auth-token \
                  /usr/local/share/lua/5.1/kong/plugins/custom-auth-authenticator

# Enable the custom plugins by default (compose may also set this).
ENV KONG_PLUGINS=bundled,custom-auth-token,custom-auth-authenticator

# Drop back to the unprivileged kong user used by the base image.
USER kong
