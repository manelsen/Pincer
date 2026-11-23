#!/bin/sh
set -eu

echo "--- STARTUP DEBUG ---"
echo "Current directory: $(pwd)"
echo "---------------------"

epmd -daemon

mix pincer.onboard --non-interactive --accept-risk --yes --if-missing

exec mix pincer.server "$@"
