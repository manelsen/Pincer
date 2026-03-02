#!/bin/sh
set -eu

epmd -daemon

# Keep startup deterministic for fresh volumes.
mix ecto.migrate

exec mix pincer.server "$@"
