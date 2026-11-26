# Auditoria de qualidade de código, arquitetura e SRP — Pincer (`0.2.0`)

Escopo verificado no repositório na release `0.2.0`: `lib/` (289 arquivos `.ex`) + `packages/` (25 pacotes, 111 arquivos `.ex`) + `test/` (`test/pincer/architecture/` com 28 arquivos de testes arquiteturais).

Arquitetura atual:
- Persistência **exclusivamente em SQLite embarcado** via `Pincer.Infra.SQLite` (`lib/pincer/infra/sqlite.ex`) e `Pincer.Adapters.Storage.SQLite` (`lib/pincer/adapters/storage/sqlite.ex`), com FTS5 e `sqlite-vec` opcional (fallback para similaridade por cosseno em Elixir).
- Canais e provedores LLM organizados como 25 pacotes isolados em `packages/`, compartilhando contratos via `packages/pincer_ports/`, helpers transversais via `packages/pincer_shared/` e base compatível OpenAI via `packages/pincer_openai_compat/`. `lib/pincer/channels/` contém apenas `lib/pincer/channels/supervisor.ex` e `lib/pincer/channels/factory.ex`.
- Fronteiras arquiteturais verificadas em tempo de compilação pelo compilador `:boundary` (`mix.exs` com `warnings_as_errors: true`) e em tempo de teste por `test/pincer/boundary_exports_test.exs` e `test/pincer/architecture/`.

---

## 0. Status das correções verificadas

| Achado original | Status | Evidência atual no repositório |
|---|---|---|
| Fronteiras compiladas + sub-fronteiras em Core | **corrigido** | Camadas e slices em `lib/pincer/core.ex`, `lib/pincer/ports.ex`, `lib/pincer/adapters.ex`, `lib/pincer/llm.ex` e `lib/pincer/cli.ex`, verificadas por `mix boundary.spec` e `test/pincer/architecture/core_sub_boundaries_test.exs`. |
| Decomposição SRP dos god modules (`SRP-001`..`SRP-006`) | **corrigido** | Fachadas reduzidas: `telegram.ex` (135 LOC), `file_system.ex` (294 LOC), `client.ex` (118 LOC), `server.ex` (378 LOC), `pairing.ex` (329 LOC) e `project_orchestrator.ex` (287 LOC), unificado em `lib/pincer/core/project_fsm.ex`. |
| `Tools.Media` bypassava `Ports.TTS` e `Ports.Sandbox` | **corrigido** | `lib/pincer/ports/tts.ex` (`Pincer.LLM.TTS` em `lib/pincer/llm/tts.ex`) e `pdftotext` confinado via `Pincer.Core.WorkspaceGuard` + `Pincer.Ports.Sandbox` em `lib/pincer/adapters/tools/media.ex`. |
| Blocos `rescue` amplos e silenciosos | **corrigido** | Erros estreitados e crashes propagados em `lib/pincer/core/executor/tool_runner.ex`, `lib/pincer/adapters/tools/workflow.ex`, `lib/pincer/core/executor/prompt_assembly.ex` e `lib/pincer/core/executor.ex`. |
| GenServer só para ETS e DETS por chamada | **corrigido** | Transições serializadas e tabelas ETS `:protected` em `lib/pincer/core/circuit_breaker.ex`, `lib/pincer/core/rate_limiter.ex` e `lib/pincer/core/pairing/store.ex`. |
| Catálogo triplicado em `Core.UX` e ANSI duplicado | **corrigido** | `@command_catalog` único em `lib/pincer/core/ux.ex` e helpers centralizados em `lib/pincer/utils/ansi.ex` (`lib/pincer/cli.ex`, `lib/mix/tasks/pincer.server.ex`, `lib/pincer/utils/logger_formatter.ex`). |
| Paridade de manifests e higiene de pacotes (`CLEAN-002`) | **corrigido** | Paridade byte a byte entre `priv/plugins/` e `packages/` (`packages/pincer_telegram/priv/pincer_plugin.yaml` e irmãos), macro `__using__` em `packages/pincer_openai_compat/lib/pincer/llm/providers/openai_compat.ex` e `test/pincer/architecture/package_hygiene_test.exs`. |
| Aprovação de `safe_shell` e política de workspace | **corrigido** | `lib/pincer/adapters/tools/safe_shell.ex` delega validação e revalidação para `lib/pincer/core/workspace_guard.ex`; SSRF centralizado em `lib/pincer/utils/network_guard.ex`. |
| `write_yaml/2` cirúrgico (`CLEAN-003`) | **corrigido** | `lib/pincer/config.ex` edita chaves escalares cirurgicamente via `put_scalar/3`, preservando seções irmãs (`test/pincer/config/surgical_write_yaml_test.exs`). |
| Módulos mortos em Core (`CLEAN-001`) | **corrigido** | Removidos e verificados por `test/pincer/architecture/dead_core_modules_removed_test.exs`. |
| Higiene de testes (`TEST-001`) e `/status` no CLI (`DOC-002`) | **corrigido** | Helpers `test/support/llm_helpers.ex` e `test/support/sync_helpers.ex` com `test/pincer/architecture/test_hygiene_test.exs`; `/status` implementado em `lib/pincer/cli.ex` e documentado em `docs/SPECS/CLI_INTERACTIVE.md`. |

---

## 1. Arquitetura de armazenamento e pacotes (estado atual)

### 1.1 Persistência SQLite embarcada

Toda a camada de persistência converge para um único backend:
- Infraestrutura de conexão, pool/GenServer, health check e suporte opcional a `sqlite-vec`: `lib/pincer/infra/sqlite.ex` (694 LOC).
- Implementação dos callbacks de `Pincer.Ports.Storage` (`lib/pincer/ports/storage.ex`): `lib/pincer/adapters/storage/sqlite.ex` (1.929 LOC), combinando mensagens, FTS5, grafo de conhecimento, checkpoints (`lib/pincer/adapters/storage/checkpoint.ex`), estado de pairing, projetos e busca vetorial (`vec_nodes` ou fallback de cosseno).
- Helpers puros sem I/O de banco isolados em `lib/pincer/adapters/storage/memory_helpers.ex` (178 LOC) e cobertos por `test/pincer/adapters/storage/memory_helpers_test.exs`.

### 1.2 Layout monorepo em `packages/`

Os 25 pacotes locais na versão `0.2.0` funcionam como dependências `path:` em `mix.exs` e pacotes Hex independentes (verificados por `scripts/check_packages.exs` e `test/pincer/architecture/package_isolation_test.exs`):
- Contratos, utilitários de canais e base OpenAI (3): `packages/pincer_ports/`, `packages/pincer_shared/`, `packages/pincer_openai_compat/`.
- Canais (9): `packages/pincer_cli/`, `packages/pincer_dingtalk/`, `packages/pincer_discord/`, `packages/pincer_feishu/`, `packages/pincer_line/`, `packages/pincer_slack/`, `packages/pincer_telegram/`, `packages/pincer_webhook/`, `packages/pincer_whatsapp/`.
- Provedores LLM (13): `packages/pincer_anthropic/`, `packages/pincer_deepseek/`, `packages/pincer_google/`, `packages/pincer_groq/`, `packages/pincer_minimax/`, `packages/pincer_mistral/`, `packages/pincer_moonshot/`, `packages/pincer_ollama/`, `packages/pincer_openai/`, `packages/pincer_opencode_zen/`, `packages/pincer_openrouter/`, `packages/pincer_qwen/`, `packages/pincer_zhipu/`.

No aplicativo raiz, `lib/pincer/channels/supervisor.ex` e `lib/pincer/channels/factory.ex` apenas inicializam e conectam os adaptadores configurados em `config.yaml` via `PincerPorts.Channel` (`packages/pincer_ports/lib/pincer_ports/channel.ex`).

---

## 2. Módulos grandes restantes (acompanhamento pós-0.2.0)

Após os splits `SRP-001`..`SRP-006`, todas as 6 fachadas principais estão enxutas (`118` a `378` LOC). Os maiores arquivos ainda concentrados para refatoração gradual pós-`0.2.0` são:

| Módulo | LOC | Responsabilidades acumuladas | Direção sugerida |
|---|---|---|---|
| `lib/pincer/adapters/storage/sqlite.ex` | 1.929 | Queries de mensagens, FTS5, grafo, memória semântica, checkpoints, projetos e pairing no mesmo arquivo | Quebrar por agregado (`Messages`, `Graph`, `Memory`, `Checkpoints`, `Projects`) |
| `packages/pincer_discord/lib/pincer/channels/discord.ex` | 1.069 | Consumer Nostrum, slash commands, interações de menu, anexos e envio em chunks | Extrair `.Commands`, `.Interactions`, `.Attachments` |
| `lib/pincer/config.ex` | 933 | Load de `.env` + YAML, allowlist em `Application`, detecção de sandbox/storage e edição cirúrgica de YAML | Separar `Config.Loader`, `Config.Applier` e `Config.YamlWriter` |
| `lib/pincer/adapters/connectors/mcp/manager.ex` | 743 | Ciclo de vida dos servidores MCP, descoberta, filtragem e despacho de ferramentas | Extrair registro/descoberta de ciclo de supervisão |
| `lib/pincer/core/llm/skills_sidecar_policy.ex` | 722 | Validação de flags `docker run`, mounts, envs e digest para sidecar de skills | Isolar construção/validação de argv Docker |
| `lib/pincer/infra/sqlite.ex` | 694 | GenServer de conexão Exqlite, DDL de schema, carregamento `sqlite-vec` e resolução de backend | Separar DDL e loader `sqlite-vec` |
| `packages/pincer_whatsapp/lib/pincer/channels/whatsapp.ex` | 659 | Bridge Go/Erlang, comandos, mídia e envio | Extrair handlers de comando e mídia |
| `lib/mix/tasks/pincer.onboard.ex` | 618 | Flags CLI, prompts interativos, escrita de `.env` e renderização de plano | Extrair prompter interativo e escritor `.env` |
| `lib/pincer/core/onboard.ex` | 596 | Planejamento local/remoto, aplicação de plano, deep merge e serialização | Separar planejamento, aplicação e remoto |
| `lib/pincer/core/executor.ex` | 506 | Loop principal já modularizado via `Ctx`/`PromptAssembly`/`ToolRunner`, mas com funções de aridade alta | Encapsular estado de fallback/streaming em `Ctx` |

---

## 3. Suíte de testes e governança arquitetural

Métricas medidas em `test/` na release `0.2.0`:

| Métrica | Valor observado | Guarda automatizada |
|---|---|---|
| Arquivos de teste arquitetural em `test/pincer/architecture/` | 28 | `mix qa` / `mix sprint.check` |
| Arquivos com `async: true` / `async: false` | 187 / 152 | — |
| Chamadas `Application.ensure_all_started(:pincer)` (arquivos) | 4 em arquivos de teste (5 incluindo `test_hygiene_test.exs`) | `test/pincer/architecture/test_hygiene_test.exs` |
| Ocorrências de `Process.sleep` em testes (excluindo guarda AST) | 18 (zero `>= 5_000`ms) | `test/pincer/architecture/test_hygiene_test.exs` |
| Chamadas cruas de `:llm_providers` fora de `test/support/` | 7 em `test/pincer/llm/tts_test.exs` (teto `<= 10`) | `test/pincer/architecture/test_hygiene_test.exs` |

---

## 4. Verificado e descartado como falso positivo

- **Criação dinâmica de átomos a partir de entrada não confiável**: não ocorre em `packages/`; as chamadas restantes em `lib/` operam sobre listas configuradas ou usam `String.to_existing_atom/1` (por exemplo em `lib/pincer/adapters/tools/args.ex`).
- **Uso de `Process.sleep` no loop principal do Executor**: `lib/pincer/core/executor.ex` não bloqueia com `Process.sleep`; o temporizador de ferramentas usa `Process.send_after/3` em `lib/pincer/adapters/tools/timer_server.ex`.

---

## 5. Próximos passos (pós-0.2.0)

1. **Quebrar os módulos grandes remanescentes** (§2): iniciar por `lib/pincer/adapters/storage/sqlite.ex`, `packages/pincer_discord/lib/pincer/channels/discord.ex` e `lib/pincer/config.ex`.
2. **Zerar chamadas cruas de `:llm_providers` restantes**: migrar `test/pincer/llm/tts_test.exs` para `test/support/llm_helpers.ex` e apertar `@max_raw_llm_providers_puts` para `0` em `test/pincer/architecture/test_hygiene_test.exs`.
3. **Publicação no Hex (`REL-001`)**: executar manualmente `bash scripts/hex_publish.sh` após autenticação com `mix hex.user auth`.
