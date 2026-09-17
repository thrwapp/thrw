#!/bin/sh
# Turns EMQX_RELAY_USERNAME / EMQX_RELAY_PASSWORD (required at container
# run time, never baked into the image) into the authentication
# bootstrap file that emqx.conf's `authentication[0].bootstrap_file`
# points at, then hands off to EMQX's own entrypoint. See
# docs/handoffs/80.md for why this is a single shared credential rather
# than per-tenant auth.
set -eu

: "${EMQX_RELAY_USERNAME:?EMQX_RELAY_USERNAME must be set - the shared relay MQTT credential (see docs/handoffs/80.md)}"
: "${EMQX_RELAY_PASSWORD:?EMQX_RELAY_PASSWORD must be set - the shared relay MQTT credential (see docs/handoffs/80.md)}"

bootstrap_dir="/opt/emqx/data/authn-bootstrap"
bootstrap_file="$bootstrap_dir/relay-users.csv"

mkdir -p "$bootstrap_dir"
{
  printf 'user_id,password,is_superuser\n'
  printf '%s,%s,false\n' "$EMQX_RELAY_USERNAME" "$EMQX_RELAY_PASSWORD"
} > "$bootstrap_file"
chmod 600 "$bootstrap_file"

exec /usr/bin/docker-entrypoint.sh "$@"
