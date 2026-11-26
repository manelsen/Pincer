# pincer_telegram

> **Status: extracted standalone channel package**
>
> `pincer_telegram` lives at `packages/pincer_telegram/` as an independent Hex-ready
> channel package in the Pincer monorepo. It implements `Pincer.Ports.Channel`
> (`PincerPorts.Channel`) and exposes the `Pincer.Channels.Telegram` adapter
> discovered via `priv/pincer_plugin.yaml`.

## Estrutura do pacote

```text
packages/pincer_telegram/
  mix.exs                                         # deps: pincer_ports, pincer_shared, telegex, plug, earmark_parser, req
  priv/
    pincer_plugin.yaml                            # manifest descoberto por Pincer.Plugin.Manifest.discover/0
  lib/
    pincer_telegram.ex                            # PincerTelegram (entrypoint / @moduledoc)
    pincer/channels/
      telegram.ex                                 # Pincer.Channels.Telegram (Supervisor + Channel) & UpdatesProvider
      telegram/
        api.ex                                    # Pincer.Channels.Telegram.API & API.Adapter (Telegex)
        renderer.ex                               # Pincer.Channels.Telegram.Renderer (Markdown → HTML)
        response_envelope.ex                      # Pincer.Channels.Telegram.ResponseEnvelope (HTML footer + reasoning)
        session.ex                                # Pincer.Channels.Telegram.Session (GenServer por chat_id)
        session_supervisor.ex                     # Pincer.Channels.Telegram.SessionSupervisor (DynamicSupervisor)
  test/
    support/mocks.ex                              # Mox.defmock para Pincer.Channels.Telegram.API
    fixtures/telegram/                            # fixtures de payloads da Bot API
    pincer/channels/
      telegram_test.exs
      telegram_session_test.exs
      telegram_updates_provider_test.exs
```

## Uso

No monorepo Pincer, o pacote já é referenciado como `path:` dependency no `mix.exs`
da raiz (`{:pincer_telegram, path: "packages/pincer_telegram"}`). Para projetos
externos, declare a dependência no `mix.exs`:

```elixir
def deps do
  [
    {:pincer_telegram, "~> 0.1"}
  ]
end
```

E habilite o canal em `config.yaml`:

```yaml
channels:
  telegram:
    enabled: true
    adapter: "Pincer.Channels.Telegram"
    token_env: "TELEGRAM_BOT_TOKEN"
    dm_policy:
      mode: "pairing"
```

## Testes e verificação

- Suite principal no root do repositório:
  `mix test test/pincer/channels/telegram_test.exs test/pincer/channels/telegram_session_test.exs test/pincer/channels/telegram_updates_provider_test.exs test/pincer/channels/telegram_response_envelope_test.exs`
- Build e testes isolados do pacote standalone:
  `elixir scripts/check_packages.exs pincer_telegram`
