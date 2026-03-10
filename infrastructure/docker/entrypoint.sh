#!/bin/sh
set -eu

echo "--- STARTUP DEBUG ---"
echo "Current directory: $(pwd)"
echo "Checking WhatsApp bridge: $(ls -l infrastructure/whatsapp/whatsapp_bridge || echo 'NOT FOUND')"
echo "Checking MCP shell server: $(ls -l infrastructure/mcp/shell_server.py || echo 'NOT FOUND')"
echo "Checking MCP directory content:"
ls -la /app/infrastructure/mcp/ || echo "MCP DIR NOT ACCESSIBLE"
echo "Checking Python venv: $(ls -l /app/infrastructure/mcp/venv/bin/python3 || echo 'NOT FOUND')"
echo "Testing Python venv: $(/app/infrastructure/mcp/venv/bin/python3 --version || echo 'EXECUTION FAILED')"
echo "---------------------"

epmd -daemon

mix pincer.onboard --non-interactive --accept-risk --yes --if-missing

export PGHOST="${PINCER_DB_HOST:-postgres}"
export PGPORT="${PINCER_DB_PORT:-5432}"
export PGUSER="${PINCER_DB_USER:-postgres}"

until pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" >/dev/null 2>&1; do
  echo "Waiting for PostgreSQL at $PGHOST:$PGPORT..."
  sleep 1
done

mix ecto.create
mix ecto.migrate

exec mix pincer.server "$@"
