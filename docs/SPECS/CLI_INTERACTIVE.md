# CLI Interativo: Especificacoes (`mix pincer.chat`)

## Objetivo

Terminal interativo em linha de comando (`mix pincer.chat`) executado via `Mix.Tasks.Pincer.Chat.run/1` -> `Pincer.CLI.main/1`. Permite conversar com a sessao `"cli_user"`, consultar o estado da sessao (`/status`) e manter historico local persistente (`Pincer.CLI.History`).

---

## Modos de Execucao e Conexao

No boot (`Pincer.CLI.main/1`):

1. **Filtro opcional de canais**: se `args` nao estiver vazio, define `:enabled_channels` em `:pincer` com os canais informados.
2. **Modo distribuido (`connect_to_server/0`)**:
   - Garante que o node local esteja vivo com shortname `pincer_cli_<id>@localhost` e cookie `:pincer_secret`.
   - Tenta `Node.connect(:pincer_server@localhost)`. Se conectar, opera contra o servidor remoto.
3. **Modo standalone (fallback)**:
   - Se `:pincer_server@localhost` nao responder, inicia a aplicacao local via `Mix.Task.run("app.start", [])`.
   - Garante a sessao local `"cli_user"` via `Pincer.Core.Session.Registry` e `Pincer.Core.Session.Server.start_link(session_id: "cli_user")`, operando em `Node.self()`.
4. **Anexo ao canal (`attach_to_backend/1`)**:
   - Resolve o modulo de canal dinamicamente via `Pincer.CLI.backend_name/0` (`:cli_channel_adapter` ou `Pincer.Plugin.Manifest.discover/0` com `id: "cli"`, padrao `Pincer.Channels.CLI`).
   - Chama `GenServer.call({backend_name(), target_node}, :attach)` para registrar o `frontend_pid` do CLI no backend.

---

## UX e Comandos (`loop/1` e `process_command/1`)

### Banner e Prompt

```text
=== Pincer CLI v0.2 (Distributed) ===
Type /q to exit. Use /status, /clear, /history, /history N or /history clear.
[User]: _
```

O label `[User]: ` e formatado por `Pincer.CLI.prompt_label/0` usando `Pincer.Utils.ANSI.cyan/1`.

### Comandos Reservados (`Pincer.CLI.process_command/1`)

`Pincer.CLI.process_command/1` intercepta comandos locais antes de enviar mensagens ao backend:

| Entrada | Retorno | Acao em `loop/1` |
|---|---|---|
| `/quit` ou `/q` | `:quit` | Imprime `"Goodbye!"` e encerra com `System.halt(0)`. |
| `/clear` | `:clear` | Limpa a tela usando `Pincer.Utils.ANSI.clear_screen/0`. |
| `/status` | `:status` | Consulta o estado da sessao via `fetch_status/2` e exibe o resumo formatado por `format_status/1`. |
| `/history` | `{:history, 10}` | Lista as ultimas 10 entradas persistidas em `Pincer.CLI.History`. |
| `/history N` | `{:history, N}` | Lista as ultimas `N` entradas (usa `10` como fallback para valores invalidos). |
| `/history clear` | `:history_clear` | Limpa o historico persistido (`Pincer.CLI.History.clear/0`). |
| Qualquer outro texto | `{:send, msg}` | Persiste em `History.append/1`, envia com `send_message/2` e aguarda resposta em `await_response/0`. |

---

## Consulta de Status (`/status`, `fetch_status/2`, `format_status/1`)

1. **`Pincer.CLI.fetch_status/2`** (`fetch_status(target, session_id \\ "cli_user")`):
   - Quando `target == Node.self()`, chama `Pincer.Core.Session.Server.get_status(session_id)`.
   - Quando `target` e um node remoto, executa `:rpc.call(target, Pincer.Core.Session.Server, :get_status, [session_id])`.
   - Quando `target` e um `pid` (em testes), chama `GenServer.call(target, :get_status)`.
   - Normaliza falhas de processo/RPC (`:exit`, `{:badrpc, reason}`, `{:error, reason}`) para `{:error, ...}` sem derrubar o loop interativo.
2. **`Pincer.CLI.format_status/1`**:
   - Formata estado valido (`{:ok, state}` ou mapa `state`) exibindo `Idle`/`Working`, `Session`, `Agent` (`root_agent_id`) e `Model` (`provider:model` via `model_override`, ou `default`).
   - Formata `{:error, ...}` e `{:badrpc, ...}` com mensagem amigavel de sessao offline ou node inacessivel, exibida com `Pincer.Utils.ANSI.warn/1`.

---

## Protocolo de Comunicacao (`send_message/2` e `await_response/0`)

1. **Envio (`Pincer.CLI.send_message/2`)**:
   - Dispara `GenServer.cast({backend_name(), node}, {:user_input, msg})` (ou diretamente para o `pid` quando `is_pid(node)`).
   - O canal `Pincer.Channels.CLI` converte `{:user_input, text}` em `IncomingMessage.new("cli_user", text)` e encaminha para `PincerPorts.Session.process_input("cli_user", incoming)`.
2. **Recepcao (`await_response/0`)**:
   - O canal `Pincer.Channels.CLI` assina `"session:cli_user"` no PubSub e envia eventos para o `frontend_pid` anexado como `{:cli_output, text}`.
   - `await_response/0` imprime `Pincer.Utils.ANSI.ok("[Pincer]: " <> text)`:
     - Mensagens de status intermediarias iniciadas pelos prefixos `"📐"` ou `"⚙️"` mantem `await_response/0` em loop aguardando a resposta final.
     - Qualquer outra mensagem `{:cli_output, text}` encerra `await_response/0` e devolve o controle ao prompt em `loop/1`.
   - **Timeout**: apos `60_000` ms (60s) sem resposta, imprime `Pincer.Utils.ANSI.error("[Timeout] No response.")` e retorna ao prompt.

---

## Estrategia de Testes

- **Parsing puro**: `Pincer.CLI.process_command/1` para `/quit`, `/q`, `/clear`, `/status`, `/history`, `/history N`, `/history clear` e mensagens normais.
- **Status**: `Pincer.CLI.format_status/1` (estados `Idle`/`Working`, `model_override`, erros e `:badrpc`) e `Pincer.CLI.fetch_status/2` (com `pid` simulado, sessao local ausente e node remoto offline).
- **Envio e configuracao**: `Pincer.CLI.send_message/2` com processo simulado, `Pincer.CLI.backend_name/0` e `Pincer.CLI.prompt_label/0` (`Pincer.Utils.ANSI`).
- **Historico**: persistencia e limpeza em `test/pincer/cli/history_test.exs`.
