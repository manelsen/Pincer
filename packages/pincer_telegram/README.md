# pincer_telegram

> **Status: pre-extraction scaffold**
>
> Este diretório mostra a estrutura que o pacote Hex `pincer_telegram` terá quando
> `pincer` for publicado no Hex.pm. A extração física requer que `pincer` esteja
> disponível como dep resolvível (Hex ou umbrella) — sem isso, o Mix não consegue
> compilar deps que dependem do projeto pai.

## Estrutura planejada

```
pincer_telegram/
  mix.exs                          # {:pincer, "~> 0.1"}, {:telegex, "~> 1.8"}
  lib/
    pincer_telegram.ex             # ponto de entrada / @moduledoc
    pincer/channels/
      telegram.ex                  # Supervisor + UpdatesProvider
      telegram/
        api.ex                     # Behaviour + Telegex adapter
        renderer.ex                # Markdown → HTML
        session.ex                 # GenServer de sessão por chat_id
        session_supervisor.ex      # DynamicSupervisor
  priv/
    pincer_plugin.yaml             # manifest descoberto via :code.get_path()
  test/
    support/
      mocks.ex                     # Mox.defmock(APIMock, for: API)
      telegram_stub.ex             # stub leve sem Mox
    pincer/channels/
      telegram_test.exs
      telegram_session_test.exs
      telegram_updates_provider_test.exs
```

## Caminho de migração

1. Publicar `pincer` no Hex.pm (`mix hex.publish`)
2. Ajustar `packages/pincer_telegram/mix.exs` → `{:pincer, "~> 0.1"}`
3. Mover os arquivos de `lib/pincer/channels/telegram*` para este pacote
4. Remover `telegex` do `mix.exs` principal
5. Remover `Telegram` e `Telegram.API` dos exports de `Pincer.Channels`
6. Publicar `pincer_telegram` no Hex.pm

## Uso (após publicação)

```elixir
# mix.exs do usuário
{:pincer, "~> 0.1"},
{:pincer_telegram, "~> 0.1"}
```

```yaml
# config.yaml — o adapter: é opcional (vem do manifest)
channels:
  telegram:
    enabled: true
    token_env: "TELEGRAM_BOT_TOKEN"
```
