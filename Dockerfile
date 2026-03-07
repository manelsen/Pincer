FROM golang:1.25 AS whatsapp-builder

WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev build-essential && \
    rm -rf /var/lib/apt/lists/*
COPY infrastructure/whatsapp ./infrastructure/whatsapp
RUN cd infrastructure/whatsapp && go build -o whatsapp_bridge main.go

FROM elixir:1.18-slim AS builder

ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config ./config

RUN mix deps.get --only prod
RUN mix deps.compile

COPY lib ./lib
COPY priv ./priv
COPY infrastructure/whatsapp ./infrastructure/whatsapp
COPY --from=whatsapp-builder /app/infrastructure/whatsapp/whatsapp_bridge ./infrastructure/whatsapp/whatsapp_bridge
COPY config.yaml ./config.yaml
COPY TODO.md ./TODO.md
COPY README.md ./README.md
COPY LICENSE ./LICENSE

RUN mix compile

FROM elixir:1.18-slim AS runtime

ARG APP_UID=1000
ARG APP_GID=1000

ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/app \
    MIX_HOME=/app/.mix \
    HEX_HOME=/app/.hex

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates libsqlite3-0 inotify-tools nodejs npm python3 python3-venv python3-pip && \
    rm -rf /var/lib/apt/lists/* && \
    groupadd --gid "${APP_GID}" pincer && \
    useradd --uid "${APP_UID}" --gid pincer --home /app --shell /bin/sh --create-home pincer

WORKDIR /app

# Install Python dependencies directly in runtime to avoid relocation issues
RUN mkdir -p /app/infrastructure/mcp && \
    python3 -m venv /app/infrastructure/mcp/venv && \
    /app/infrastructure/mcp/venv/bin/pip install --no-cache-dir "mcp[cli]" fastmcp

COPY --from=builder /app/_build /app/_build
COPY --from=builder /app/deps /app/deps
COPY --from=builder /app/lib /app/lib
COPY --from=builder /app/priv /app/priv
COPY --from=builder /app/config /app/config
COPY --from=builder /app/infrastructure/whatsapp /app/infrastructure/whatsapp
COPY infrastructure/mcp/shell_server.py /app/infrastructure/mcp/shell_server.py
COPY --from=builder /app/mix.exs /app/mix.exs
COPY --from=builder /app/mix.lock /app/mix.lock
COPY --from=builder /app/config.yaml /app/config.yaml
COPY --from=builder /app/TODO.md /app/TODO.md
COPY --from=builder /app/README.md /app/README.md
COPY --from=builder /app/LICENSE /app/LICENSE
COPY --from=builder /root/.mix /app/.mix
COPY --from=builder /root/.hex /app/.hex
COPY infrastructure/docker/entrypoint.sh /app/infrastructure/docker/entrypoint.sh

RUN mkdir -p /app/db /app/logs /app/sessions /app/memory /app/workspaces && \
    chmod +x /app/infrastructure/docker/entrypoint.sh && \
    chown -R pincer:pincer /app

USER pincer

ENTRYPOINT ["/app/infrastructure/docker/entrypoint.sh"]
