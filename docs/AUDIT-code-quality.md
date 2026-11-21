# Auditoria de code smells, idiomas e SRP — Pincer

Escopo: `lib/` (247 arquivos, ~46,6k LOC) + `packages/` (74 arquivos, ~11,2k LOC) + `test/` (264 `.exs`).

**Achados de alta confiança foram verificados manualmente** — os que se mostraram falsos positivos estão listados no §8, para não induzir refatoração desnecessária.

---

## 0. Status das correções (rodada 1)

Já corrigido neste mesmo PR; o restante segue como backlog priorizado no §9.

| Achado | Status | O que mudou |
|---|---|---|
| §1.1 aprovação de `safe_shell` pulava validação | **corrigido** | `execute/2` revalida o comando exato com `approved_command_allowed?/2` antes de executar; `approved_command_allowed?/2` deixou de ser no-op quando `restrict_to_workspace: false`. Testes em `safe_shell_test.exs`. |
| §1.2 transporte `:os` sem guarda | **corrigido** | `Sandbox.Local.run_os/4` passa por `WorkspaceGuard.command_allowed?/2`; comando fora do allowlist retorna `{:error, {:command_not_allowed, _}}`. |
| §1.3 dois motores de política de shell | parcial | `:os` e aprovação já usam `WorkspaceGuard`; `SafeShell.parse_and_validate/2` ainda é próprio (operação separada, mesmo veredito). |
| §1.4 SSRF no `browser` | **corrigido** | `Web.validate_url/1` virou público; `browser.navigate` rejeita hosts internos e esquemas não-http sem tocar no pool. |
| §1.5 SSH sem validação de path remoto | **corrigido** | `remote_workspace` rejeita `..`, NUL e metacaracteres; comando remoto honra `restrict_to_workspace`. |
| §1.6 HTTP sem timeout | **corrigido** | `receive_timeout`/`connect_timeout` em LINE, Feishu (incl. token) e DingTalk. |
| §1.7 Audit trail inexistente | **corrigido** | `AuditLog.record/3` é chamado nas três transições de aprovação de tool; `RBAC` barra aprovação quando o papel configurado não tem `:approve_tools` (sessões sem papel configurado continuam livres). |
| §2.4 `write_yaml/2` descartava seções | **corrigido** | Edição cirúrgica só das chaves `llm.*`; `set_model/2` não recarrega `.env` nem reescreve config alheia. 6 testes em `config_set_model_test.exs`. |
| §4 módulos mortos | **corrigido** | Removidos `model_router`, `project_board`, `contract_engine`, `capabilities`, `command_queue`, `release_validation`, `storage/port`, `core/sub_agent`, árvore `channels/matrix` e o shim `Pincer.hello/0` (com os testes correspondentes). `RBAC`/`AuditLog` foram ligados em vez de removidos. |
| §7 arquivos soltos de teste | **corrigido** | 10 scripts manuais movidos para `scripts/manual/`; `security_audit_test.exs` e `storage_smoke_test.exs` movidos para `test/pincer/` (este último agora respeita `PINCER_DB_*`); `pincer_kimi_test.exs` removido. |

---

## Resumo executivo

| # | Problema | Onde | Impacto |
|---|---|---|---|
| 1 | `safe_shell` com aprovação **pula toda validação** de comando | `adapters/tools/safe_shell.ex:157` | Segurança |
| 2 | `Matrix.Session` não existe; supervisor referencia módulo fantasma | `channels/matrix/session_supervisor.ex:24` | Crash em runtime |
| 3 | 3 canais reimplementam o mesmo pipeline de entrada (DM gate, pairing, sessão, chunking) | telegram/discord/whatsapp | ~1.500 LOC duplicadas |
| 4 | `doctor` / `security_audit` / `onboard` são 3 cópias do mesmo pipeline de auditoria | `core/doctor.ex`, `security_audit.ex`, `onboard.ex` | ~250 LOC duplicadas, relatórios divergentes |
| 5 | `postgres.ex` ↔ `sqlite.ex`: ~400 LOC de copy-paste + **drift de comportamento** | `storage/adapters/*` | Bugs por backend |
| 6 | 8 módulos "mortos" (só testes os chamam) | ver §4 | Manutenção |
| 7 | `write_yaml/2` reconstroi o config.yaml a partir de heredoc e descarta seções | `config.ex:635` | Perda de config |

---

## 1. Segurança (prioridade máxima)

### 1.1 Aprovação de `safe_shell` desliga a validação

`lib/pincer/adapters/tools/safe_shell.ex:157`

```elixir
cond do
  approval_granted ->
    Logger.info("[SAFE-SHELL] Pre-approved command: #{command}")
    execute_in_sandbox(command, ...)
```

O fluxo de aprovação funciona (`tool_runner.ex:216` → `ToolRuntime.execute(..., approval_granted: true)` → injeta `"approval_granted"` no contexto), mas ao chegar com aprovação o comando vai direto para o sandbox **sem passar por** `@dangerous_chars`, `@multiline_or_line_continuation` nem pelo whitelist de `parse_and_validate/1`. `SafeShell.approved_command_allowed?/2` — a função que deveria revalidar o comando aprovado — **não tem nenhum chamador em `lib/`** (só testes).

Correção: ao receber `approval_granted`, revalidar o comando exato que o usuário viu via `approved_command_allowed?/2`; sem isso a aprovação vira execução arbitrária.

### 1.2 Transporte `:os` do sandbox local executa `sh -c` sem guarda

`lib/pincer/adapters/sandbox/local.ex:118` — `System.cmd("sh", ["-c", command])`, sem `WorkspaceGuard.command_allowed?/2`. O moduledoc afirma confinamento, mas ele cobre apenas o `cwd`. Gate a rota `:os` ou rejeite-a fora de `restrict_to_workspace`.

### 1.3 Dois motores de política de shell

`safe_shell.ex:69-82,101-127` duplica constantes e reimplementa `command_allowed?/2` de `core/workspace_guard.ex:14-16,138-160` com **tokenização diferente** (SafeShell aceita `du`/`find`, WorkspaceGuard não). Um comando pode passar num e falhar no outro. Consolide em `WorkspaceGuard`.

### 1.4 SSRF parcial

`tools/web.ex:109` valida apenas `web_fetch`; `tools/browser.ex:128` aceita `url` sem `Web.validate_url/1`. Além disso `resolves_to_private_ip?/1` resolve o DNS e `Req` resolve de novo na conexão (janela de rebinding). Torne `validate_url/1` público, reutilize em `browser`/`media` e fixe o IP validado.

### 1.5 SSH sem validação de caminho remoto

`adapters/sandbox/ssh.ex:214-231` valida só o `cwd` **local**; `remote_workspace` com `../..` escapa sem erro.

### 1.6 HTTP sem timeout

`pincer_line/.../api.ex`, `pincer_feishu/.../api.ex:233`, `pincer_dingtalk/.../api.ex:41` fazem `Req.post/get` sem `receive_timeout` — um endpoint travado bloqueia o processo chamador indefinidamente. Crie um wrapper HTTP único com timeout + retry (hoje existem 3 sites de mapeamento de erro independentes: `web.ex`, `github.ex`, `media.ex`).

### 1.7 Audit trail inexistente

`core/audit_log.ex:38` (`AuditLog.record/3`) e `core/rbac.ex` não têm **nenhum** chamador em `lib/`. Eventos sensíveis (aprovação de shell, pairing, escrita em config) não são persistidos, embora o moduledoc de `AuditLog` afirme o contrário.

---

## 2. Duplicação (maior custo de manutenção)

### 2.1 Pipeline de entrada dos canais — 3 cópias (+2 parciais)

| Preocupação | Hoje em | Deveria viver em |
|---|---|---|
| Loop de entrada (gate → comando → shortcut → project collect → `process_input`) | `telegram.ex:852-967`, `discord.ex:273-371`, `whatsapp.ex:179-242` | `pincer_shared`: `Inbound.dispatch/2` |
| Gate DM (```Policy.allow?(:dm_access, ...)```) | `telegram.ex:1742`, `discord.ex:392`, `whatsapp.ex:499` | `Shared.DmPolicy` |
| Fluxo `/pair` + textos de erro | `telegram.ex:1693`, `discord.ex:555`, `whatsapp.ex:347` | `Shared.Pairing` |
| Resolver + garantir sessão | 5 adaptadores (inclui `slack.ex:132`, `webhook.ex:351`) | `Shared.SessionBridge` |
| Chunking de mensagem | `telegram.ex:539` (4000), `discord.ex:169` (1900), `whatsapp.ex:635` (3500) | `Shared.Chunker` |
| Kickoff de projeto | `telegram.ex:1808`, `discord.ex:1027`, `whatsapp.ex:244` | `Shared.ProjectBridge` |
| Anexos (mime, sanitize_filename, attachment_ref) | `telegram.ex:1156-1349`, `discord.ex:1156-1263` | `Shared.Attachments` |
| Formatação markdown/HTML | `telegram.ex:400-466`, `discord.ex:238`, `slack.ex:84` | `Shared.Format` |

`pincer_shared` hoje contém apenas `TokenCache` e `WebhookVerifier` — está subutilizado exatamente onde deveria concentrar código.

### 2.2 LLM client: dois caminhos idênticos

`lib/pincer/llm/client.ex` — `chat_completion/2` (`:62-141`) e `stream_completion/2` (`:261-340`) são o mesmo bloco de 18 linhas de resolução de provider + `cond` + `AuthProfiles.resolve` copiado; e `maybe_handle_terminal_failure/13` aparece **verbatim duas vezes** (`:718-836` e `:836-954`), mudando só o literal `:stream_completion`/`:chat_completion`. Um `dispatch(action, messages, opts)` resolve ambos.

### 2.3 Storage adapters — ~400 LOC idênticas

`sqlite.ex` (1644) e `postgres.ex` (1330) implementam os mesmos 31 callbacks; são cópias literais com dialeto trocado:

`maybe_put/3`, `stringify_keys/1`, `build_memory_metadata/4`, `document_matches_opts?/2`, `match_workspace?/2`, `memory_forgotten?/1`, `incident_query?/1`, `build_citation/1`, `extract_session_id/1`, `build_structured_id/2`, `build_pattern_key/2`, `search_tokens/1`, `document_result/2`, além dos blocos de dedupe de `save_learning`/`save_tool_error`.

Extraia `Storage.MemoryScoring` + `Storage.SearchUtils` (puros, testáveis sem DB) e deixe em cada adapter só o SQL.

**Drift verificado entre backends** (candidatos a bug real):

| Callback | Postgres | SQLite |
|---|---|---|
| `index_document/4` metadata | encaminha todas as chaves | allowlist de 12 cláusulas descarta `skeleton_hash`/`indexed_at` → `needs_indexing?/2` re-embeda o arquivo a cada sync |
| `upsert_pairing_state/4` | guarda `sender_id` cru | `to_string(sender_id)` → lookup por inteiro falha só no SQLite |
| `save_message/3` | `{:ok, %Message{}}` | `{:ok, %{...,inserted_at: "iso-string"}}` |
| `get_messages/1` erro | propaga | engole e devolve `[]` |
| `touch_memory_access/1` | atualiza colunas | só dentro do JSON `data` |
| `search_messages/2` | sem chave `:score` | `score: 0.5` |
| `memory_report/1` | 3 agregados SQL | carrega todos os documentos em memória |
| `search_documents_fts/3` | filtra em SQL | busca `limit*4` e filtra em Elixir |

### 2.4 Modo duplo/triplo de config e auditoria

- `doctor.ex:320-576` × `security_audit.ex:33-217` × `onboard.ex:310-362`: normalização de DM mode, checagem de token, load de config, `counts/1`, `status_from_counts/1`, `link_check/2`, `make_run_id/1` — cópias com strings diferentes. Os relatórios **divergem**: `doctor.ex:34` não inclui `"webhook"` entre os canais com token, `security_audit.ex:33` inclui.
- `access_policy.ex:91` tem uma **terceira** normalização de DM mode.
- `config.ex:432-481` reimplementa `detect_storage_backend/2` de `infra/sqlite.ex:259` (mesmas listas de alias, mesmo `first_non_empty`).

### 2.5 Utilitários repetidos (cross-cutting)

| Helper | Ocorrências |
|---|---|
| `normalize_session_id` | 6 (`memory.ex:222`, telegram/discord/whatsapp session, webhook) |
| `normalize_text` (nil → `""`) | 9+ |
| `via_tuple` de sessão | 6 adaptadores |
| `truncate` (corta + `"..."`/`"…"`) | 4 (`tool_runner.ex:256,292`, `tool_call.ex:139`, `memory_recall.ex:598`) |
| `content_to_text/1` | 2 com **semânticas diferentes** (`history.ex:151` × `memory_recall.ex:552`) |
| `fetch_required_string/2` | 2 (`channel_actions.ex:254`, `file_system.ex:762`) |
| `workspace_path` lookup | 3 (`media.ex:99`, `code_skeleton.ex:34`, `channel_actions.ex:103`) |
| `first_line/1` | 2 (`github.ex:423`, `tool_result_summary.ex:211`) |
| formatadores de erro HTTP | 3 (`github_error.ex`, `web_fetch_error.ex`, `git_inspect_error.ex`) |
| `normalize_model_override/1` | 2 byte-a-byte (`executor/ctx.ex:190`, `session/preferences.ex`) |

Crie `Pincer.Utils.Text`, `Pincer.Adapters.Tools.Args` e `Pincer.Infra.Http`.

---

## 3. Violações de SRP (god modules)

| Módulo | LOC | Responsabilidades observadas | Split sugerido |
|---|---|---|---|
| `pincer_telegram/.../telegram.ex` | 1898 | transporte, poller/offset, parse de update, comandos, callbacks/menu, DM/pairing, mídia + transcrição ffmpeg, formatação | `.Transport`, `.Poller`, `.Update`, `.Commands`, `.Menu`, `.Media`, `.Formatter` |
| `adapters/tools/file_system.ex` | 1678 | confinamento de path, 16 ações, zip-slip, edit ancorado, hashline, trash, copy/move, render JSON, **3 walkers recursivos quase idênticos** | `.Walk`, `.Edit`, `.Archive`, `.Transfer` |
| `storage/adapters/sqlite.ex` | 1644 | ver §2.3 | query-only + `MemoryScoring` |
| `storage/adapters/postgres.ex` | 1330 | idem | idem |
| `llm/client.ex` | 1295 | roteamento, auth profiles, retry engine (205 LOC, 12 args), failover ×2, stream→chat, cache ETS, transcrição, embeddings | `RetryEngine`, `Failover`, `ModelCache`, `Capabilities` |
| `pincer_discord/.../discord.ex` | 1288 | transporte, consumer, slash commands, interações, anexos, chunking | `.Consumer`, `.Commands`, `.Interactions`, `.Attachments` |
| `core/pairing.ex` | 910 | geração/hash de código, schema ETS, store DETS (abre/fecha por chamada), persistência SQL, notificação CLI/PubSub, criação de agente | `Pairing.Code`, `.Store`, `.Notifier` |
| `core/project_orchestrator.ex` | 878 | wizard, driver FSM, git branch, render markdown/kanban, retry, dono da tabela ETS | `Project.Wizard`, `.Plan`, `.Renderer`, `.Store` |
| `core/session/server.ex` | 863 | ciclo de vida GenServer, correlação de tasks, ingestão Blackboard, buffer/debounce de input, roteamento de comandos, PubSub, preferências, alignment, graph watcher | `Session.TaskCoordinator`, `.BlackboardIngestor`, `.InputBuffer`, `.CommandDispatcher` |
| `core/config.ex` | 729 | load `.env`+YAML, allowlist, escrita de ~20 chaves em `Application`, detecção de backend, **write-back de YAML** | `Config.Loader`, `.Applier`, `.Writer` |
| `core/llm/skills_sidecar_policy.ex` | 722 | na prática é um validador de argv do `docker run` (nome enganoso) | renomear → `Sandbox.DockerArgsPolicy` |
| `mix/tasks/pincer.onboard.ex` | 673 | 16 flags, prompts interativos, mutação de config, escrita de `.env`, preflight, plano, re-run do Doctor, 3 renderers | `CLI.Onboard.Prompter`, `.EnvFile`, `Report` |
| `core/doctor.ex` / `security_audit.ex` | 638 / 487 | ver §2.4 | `Doctor.Checks.*` + `Audit.Report` |
| `core/onboard.ex` | 630 | plano/apply, preflight, SSH remoto com quoting, **serializador YAML manual**, deep merge | `Onboard.Plan/.Apply/.RemotePlan` + `YamlElixir` |
| `core/memory_recall.ex` | 605 | monta bloco de prompt, sanitiza, consulta 4 backends, merge/rerank, lê `USER.md`, telemetria | `Recall.Fetcher`, `.Ranker`, `.Prompter` |
| `core/executor.ex` | 557 | loop, fallback de provider, empty-response recovery, preparo de prompt, pós-processamento de mensagem, texto de fallback | `Executor.FallbackStrategy` (linhas 270-392) |

---

## 4. Código morto / não-conectado (verificado por grep)

Só testes os referenciam; nenhum chamador em `lib/` ou `packages/`:

| Módulo | Nota |
|---|---|
| `core/llm/model_router.ex` | `route/2` sem chamadores apesar de `config.yaml` carregar `model_router`; usaria `Map.fetch!` num tier possivelmente ausente |
| `core/rbac.ex` | `RBAC.authorize/2` nunca chamado; `AuditLog` afirma depender dele |
| `core/release_validation.ex` | defaults sempre retornam `:error` |
| `session/command_queue.ex` | `Session.Server` usa seu próprio `input_buffer`; o módulo é órfão |
| `core/heartbeat/contract_engine.ex` | fora da árvore de supervisão |
| `core/project_board.ex` | segundo renderer de kanban; o vivo é `project_orchestrator.board/2` |
| `core/capabilities.ex` | catálogo morto; o vivo é `capability_discovery.ex` |
| `core/sub_agent.ex` | o vivo é `orchestration/sub_agent.ex` |
| `storage/port.ex` | contrato de 3 callbacks que ninguém implementa (adapters usam `Pincer.Ports.Storage`) |
| `channels/matrix/{api,session_supervisor}.ex` | **`Pincer.Channels.Matrix.Session` não existe** — o `DynamicSupervisor` referencia módulo inexistente |

Menores: `executor.ex:77` (`resolve_attachment_url/2`, `default_file_fetch/1` sem chamadores), `memory_recall.ex:101` (`explain/2` só em teste), `bindings.ex:27` (`conversation_ref/3` idêntico a `principal_ref/3`).

---

## 5. Código não-idiomático

**Rescue genérico escondendo bug** (77 `rescue` no total, 20 com `Exception.message`):
- `tool_runner.ex:183` — `rescue e ->` devolve `:ok`, então tool que crasha **nunca** conta em `consecutive_errors`.
- `workflow.ex:144,166,195,214,225,354` — 6 catch-alls convertem erro em string amigável; `load_tasks/1` transforma JSON corrompido em `[]` e sobrescreve o arquivo.
- `pairing.ex:293,714,875,905`, `circuit_breaker.ex:224-257`, `prompt_assembly.ex:317-338` (`rescue _ -> ""`), `memory_recall.ex:316`, `kernel.ex:352`, `feishu.ex:146`, `discord.ex:1007`, `telegram.ex:1895`, `intelligence`. 
- `executor.ex:231` — `rescue Protocol.UndefinedError` envolve o stream inteiro: qualquer erro de protocolo em normalização de tool call vira "payload inválido".

**Recursão/lista quadrática** (`acc ++ [x]` em loop):
- `file_system.ex:863,1005,1096,1327,1357,1411,1449`
- `telegram.ex:539-582` (`current <> line`), `discord.ex:180-211` (`String.length`+`String.slice` por passo, O(n²) em 128 KB)
- `plugins.ex:276` (7 sítios), `onboard.ex:648`, `failover_policy.ex:165`

**GenServer que só existe para criar ETS** (`init` = `%{}`, todo o trabalho via `:ets` de qualquer processo, transições não serializadas): `circuit_breaker.ex:18-49`, `rate_limiter.ex:1-82`, `pairing.ex` (DETS abre/sincroniza/fecha **por chamada**).

**`if`/`cond` que deveriam ser cláusulas com guard**:
- `session/server.ex:576-603` (3 níveis + `handle_call/3` chamando `handle_call/3` de novo), `:644-670` (`if`→`if`→`if`)
- `pairing.ex:130-178` (`case`→`cond`→`case`→`if`, 48 linhas), `project_orchestrator.ex:342-410` (68 linhas), `discord.ex:866-1000` (134 linhas de `case` sobre prefixo de callback)
- `tool_parser.ex:97-121` (`cond` + `Map.has_key?` onde cabe pattern matching), `file_system.ex:200-233` (`infer_action/1` adivinha a ação e reinterpreta chamada malformada em silêncio)

**Aridade cega:**
- `llm/client.ex:440` `do_request_with_retry/12`
- `executor.ex:171-252` `run_stream/8` (cinco argumentos correlatos soltos)
- `maybe_handle_terminal_failure/13` ×2

**Bang/raise em caminho que promete `{:error, _}`:** `attachments.ex:96` (`Base.decode64!`), `history.ex:222` (`:ok = File.mkdir_p`), `file_system.ex:573,1172,1569` (`File.mkdir_p`, `File.ls!`, `File.rm_rf`), `logger.ex:136`.

**Fontes de verdade triplicadas:**
- `core/ux.ex` — `@commands`, `@shortcut_routes` e `help_text/1` listam os mesmos 11 comandos (o help já omite `/think` e `/reasoning`).
- `file_system.ex` — lista de 16 ações em `spec/0`, em `validate_action_path/3` e nas cláusulas de `perform_action`.
- ANSI hardcoded: 17× em `pincer.server.ex`, 15× em `cli.ex`, mais um conjunto próprio em `logger_formatter.ex`.
- `ProjectOrchestrator.phase` (5 valores) × `ProjectFSM` (6 fases) — dois state machines que podem divergir, e `transition_fsm/3` engole o erro com `Logger.debug`.
- `config.yaml` com defaults de provider hardcoded também em `onboard.ex:484` (`"z_ai"`/`"glm-4.7"`) e `client.ex:344,367,411` (`"groq_whisper"`, `"openrouter"`, `"baai/bge-m3"`).

**`write_yaml/2` (`config.ex:635-671`)** reconstroi o arquivo inteiro a partir de um heredoc que indexa 11 chaves fixas: `KeyError` se faltar alguma e **descarte silencioso** de `memory`, `tools`, `channels`, `sandbox`.

**`String.halt` no CLI:** `cli.ex:68,85` dentro de Mix task salta supervisores e limpeza.

---

## 6. Higiene de pacotes e config

- **Manifests divergentes**: `priv/plugins/line/pincer_plugin.yaml` diz `secret_env.required: true`, o do pacote diz `false`; `slack` troca `token_env` por `app_token_env`/`bot_token_env`; `feishu`/`discord`/`dingtalk` divergem também. Uma cópia + check de `diff` no CI.
- **`mix.exs` de pacotes inconsistentes**: `pincer_discord`/`pincer_slack` sem helpers `deps()`/`package()`, sem `maintainers`, com vírgula final suspeita (`discord/mix.exs:13`); versão/descrição/licença repetidas em 26 arquivos.
- **Mocks de provedor**: 10 módulos delegam a `OpenAICompat` mudando só `base_url`, e `transcribe_audio`/`generate_embedding` `:not_implemented` aparecem **15×** e **11×** respeitivamente. Um macro/behaviour com defaults elimina a maior parte desses pacotes.

---

## 7. Suíte de testes

| Métrica | Valor |
|---|---|
| Arquivos `*_test.exs` | 250 |
| `async: true` / `async: false` / sem declaração | 141 / 99 / 25 |
| Sem `describe` | 143 (61%) |
| Com ≤2 testes | 61 (23 com ≤1) |
| `Application.ensure_all_started(:pincer)` sem tag | 24 arquivos (paga boot completo em `mix test`) |
| `Process.sleep` | 78 chamadas em 31 arquivos (inclui `sleep(10_000)` hardcoded) |
| Assertions em log | 20 em 7 arquivos |
| Bloco `put_env(:llm_providers)` + `on_exit` duplicado | 41× em ~18 arquivos |

Arquivos soltos na raiz de `test/`: `pincer_kimi_test.exs` (template `mix new`, `Pincer.hello() == :world`), `test_10_skills.exs` (script de `docker run`, 0 testes, roda no `mix test`), `test_filesystem_mcp.exs` (0 testes, `sleep(10_000)`), `storage_smoke_test.exs`, `security_audit_test.exs` (suíte real, só mal posicionada).

Faltam helpers em `test/support/`: `LLMHelpers.put_providers!/1`, `StorageHelpers.checkout!/0`.

---

## 8. O que foi verificado e **não** é problema

Evitar refatorações baseadas nestes supostos achados:

- **Embedding não persistido no Postgres** — falso: `lib/pincer/storage/graph/node.ex:134` já faz `cast(..., [:type, :data, :embedding, ...])`.
- **Score semântico invertido entre Postgres e SQLite** — falso: `postgres.ex:399` usa `1.0 - distance`, equivalente à similaridade do SQLite.
- **Criação de átomos a partir de input não confiável** — não existe: `String.to_atom` aparece em 22 sítios, todos sobre constantes ou com `to_existing_atom`/`Module.safe_concat`; `packages/` não tem nenhum.
- **`System.halt` em Mix tasks** — não há; só em `lib/pincer/cli.ex`.
- **`Process.sleep` em código de produção de `lib/pincer/core`** — não há (só em tasks e testes).

---

## 9. Ordem de ataque sugerida

1. **Segurança** (§1.1–1.3): revalidar comando aprovado, eliminar o segundo motor de política, gatear o transporte `:os`. Depois 1.4/1.5/1.6.
2. **Correções baratas de alto valor**: remover/consertar `Matrix.Session`, `model_router`, `write_yaml/2`, os 8 módulos mortos, os arquivos soltos de `test/`.
3. **Unificar auditoria de config** (§2.4) — elimina ~250 LOC e a divergência de relatórios.
4. **`pincer_shared`** (§2.1) — o maior ganho único de duplicação.
5. **Storage** (§2.3) — extrair helpers puros e alinhar o drift entre backends.
6. **SRP dos god modules** (§3) — começar por `Session.Server`, `Executor` e `LLM.Client`, que já têm seams naturais (policies, `Ctx`, `Attempt`).
7. **Higiene** (§6) e **suíte** (§7) — incrementais, sem bloquear o resto.
