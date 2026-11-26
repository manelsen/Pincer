# Auditoria de qualidade de código, arquitetura e SRP — Pincer

Escopo verificado no repositório: `lib/` (269 arquivos `.ex`, ~47,3k LOC) + `packages/` (25 pacotes, 104 arquivos `.ex`, ~14,1k LOC) + `test/` (327 arquivos `.exs`, sendo 323 `*_test.exs`, incluindo 26 testes arquiteturais em `test/pincer/architecture/`).

Arquitetura atual:
- Persistência **exclusivamente em SQLite embarcado** via `Pincer.Infra.SQLite` (`lib/pincer/infra/sqlite.ex`) e `Pincer.Adapters.Storage.SQLite` (`lib/pincer/adapters/storage/sqlite.ex`), com FTS5 e `sqlite-vec` opcional (fallback para similaridade por cosseno em Elixir).
- Canais e provedores LLM organizados como pacotes isolados em `packages/`, compartilhando contratos via `packages/pincer_ports/` e helpers transversais via `packages/pincer_shared/`. `lib/pincer/channels/` contém apenas `lib/pincer/channels/supervisor.ex` e `lib/pincer/channels/factory.ex`.
- Fronteiras arquiteturais verificadas em tempo de compilação pelo compilador `:boundary` (`mix.exs` com `warnings_as_errors: true`) e em tempo de teste por `test/pincer/boundary_exports_test.exs` e `test/pincer/architecture/`.

---

## 0. Status das correções verificadas

| Achado original | Status | Evidência atual no repositório |
|---|---|---|
| Aprovação de `safe_shell` pulava validação | **corrigido** | `lib/pincer/adapters/tools/safe_shell.ex` revalida comandos pré-aprovados via `approved_command_allowed?/2` delegando a `Pincer.Core.WorkspaceGuard` (`lib/pincer/core/workspace_guard.ex`). |
| Política duplicada entre `SafeShell` e `WorkspaceGuard` | **corrigido** | `lib/pincer/adapters/tools/safe_shell.ex` delega `validate_command/2` e `command_allowed?/2` para `lib/pincer/core/workspace_guard.ex`. |
| Transporte local e SSH sem validação suficiente | **corrigido** | `lib/pincer/adapters/sandbox/local.ex` e `lib/pincer/adapters/sandbox/ssh.ex` aplicam `WorkspaceGuard`; `ssh.ex` valida `remote_workspace` contra `..`, NUL e metacaracteres. |
| SSRF no `browser` e `web` | **corrigido** | `lib/pincer/adapters/tools/web.ex` e `lib/pincer/adapters/tools/browser.ex` delegam validação de URL para `Pincer.Utils.NetworkGuard.validate_url/1` (`lib/pincer/utils/network_guard.ex`). |
| Chamadas HTTP sem timeout nos canais | **corrigido** | `packages/pincer_line/lib/pincer/channels/line/api.ex`, `packages/pincer_feishu/lib/pincer/channels/feishu/api.ex` e `packages/pincer_dingtalk/lib/pincer/channels/dingtalk/api.ex` definem `@receive_timeout 30_000`. |
| `AuditLog` e `RBAC` desconectados | **corrigido** | `lib/pincer/core/executor/tool_runner.ex` chama `AuditLog.record/3` (`lib/pincer/core/executor/audit_log.ex`) e `RBAC.authorize/2` (`lib/pincer/core/executor/rbac.ex`) no fluxo de aprovação. |
| `write_yaml/3` descartava seções de `config.yaml` | **corrigido** | `lib/pincer/config.ex` (`Pincer.Infra.Config`) edita chaves escalares de `llm.*` cirurgicamente via `put_scalar/3`, preservando demais seções. |
| Módulos mortos em Core (`CLEAN-001`) | **corrigido** | Removidos 7 módulos mortos (`ModelRouter`, `CommandQueue`, `ContractEngine`, `ReleaseValidation`, `ProjectBoard`, `Capabilities`, `Orchestration.Scheduler`), `core/sub_agent` e a antiga árvore `storage/`, verificados por `test/pincer/architecture/dead_core_modules_removed_test.exs`. |
| Duplicação entre `doctor`, `security_audit` e `onboard` | **corrigido** | `lib/pincer/core/doctor.ex`, `lib/pincer/core/security_audit.ex` e `lib/pincer/core/onboard.ex` compartilham `lib/pincer/core/posture.ex` e `lib/pincer/core/config_probe.ex`. |
| Pipeline compartilhado em `pincer_shared` | **corrigido** | `packages/pincer_shared/lib/pincer/channels/shared.ex` provê `Inbound`, `SessionBridge`, `ProjectBridge`, `Pairing`, `Chunking`, `Formatting`, `Attachments`, `Text`, `TokenCache` e `WebhookVerifier`, adotados pelos adaptadores em `packages/`. |
| Helpers puros de memória e despacho LLM | **corrigido** | Extraídos `lib/pincer/adapters/storage/memory_helpers.ex`, `lib/pincer/adapters/tools/args.ex`, `lib/pincer/infra/http.ex`, `lib/pincer/utils/text.ex` e `lib/pincer/llm/retry_engine.ex`. |
| Acumulações quadráticas (`CLEAN-005`) | **corrigido** | Corrigidas em chunking/onboard/plugins/failover e guardadas por `test/pincer/architecture/no_quadratic_accumulations_test.exs`. |
| Arquivos soltos na raiz de `test/` | **corrigido** | 10 scripts manuais movidos para `scripts/manual/`; testes de postura e fumaça organizados em `test/pincer/security_audit_test.exs` e `test/pincer/adapters/storage/storage_smoke_test.exs`. |

---

## 1. Arquitetura de armazenamento e pacotes (estado atual)

### 1.1 Persistência SQLite embarcada

Toda a camada de persistência converge para um único backend:
- Infraestrutura de conexão, pool/GenServer, health check e suporte opcional a `sqlite-vec`: `lib/pincer/infra/sqlite.ex` (694 LOC).
- Implementação dos callbacks de `Pincer.Ports.Storage` (`lib/pincer/ports/storage.ex`): `lib/pincer/adapters/storage/sqlite.ex` (1.929 LOC), combinando mensagens, FTS5, grafo de conhecimento, checkpoints (`lib/pincer/adapters/storage/checkpoint.ex`), estado de pairing, projetos e busca vetorial (`vec_nodes` ou fallback de cosseno).
- Helpers puros sem I/O de banco isolados em `lib/pincer/adapters/storage/memory_helpers.ex` (178 LOC) e cobertos por `test/pincer/adapters/storage/memory_helpers_test.exs`.

### 1.2 Layout monorepo em `packages/`

Os 25 pacotes locais funcionam como dependências `path:` em `mix.exs` e pacotes Hex independentes (verificados por `scripts/check_packages.exs` e `test/pincer/architecture/package_isolation_test.exs`):
- Contratos e utilitários de canais (2): `packages/pincer_ports/`, `packages/pincer_shared/`.
- Canais (9): `packages/pincer_cli/`, `packages/pincer_dingtalk/`, `packages/pincer_discord/`, `packages/pincer_feishu/`, `packages/pincer_line/`, `packages/pincer_slack/`, `packages/pincer_telegram/`, `packages/pincer_webhook/`, `packages/pincer_whatsapp/`.
- Provedores LLM e base compatível OpenAI (14): `packages/pincer_openai_compat/`, `packages/pincer_anthropic/`, `packages/pincer_deepseek/`, `packages/pincer_google/`, `packages/pincer_groq/`, `packages/pincer_minimax/`, `packages/pincer_mistral/`, `packages/pincer_moonshot/`, `packages/pincer_ollama/`, `packages/pincer_openai/`, `packages/pincer_opencode_zen/`, `packages/pincer_openrouter/`, `packages/pincer_qwen/`, `packages/pincer_zhipu/`.

No aplicativo raiz, `lib/pincer/channels/supervisor.ex` e `lib/pincer/channels/factory.ex` apenas inicializam e conectam os adaptadores configurados em `config.yaml` via `PincerPorts.Channel` (`packages/pincer_ports/lib/pincer_ports/channel.ex`).

---

## 2. Violações de SRP restantes (god modules)

Módulos grandes medidos diretamente em `lib/` e `packages/` que ainda concentram múltiplas responsabilidades:

| Módulo | LOC | Responsabilidades acumuladas | Split sugerido |
|---|---|---|---|
| `lib/pincer/adapters/storage/sqlite.ex` | 1.929 | Queries de mensagens, FTS5, grafo, memória semântica, checkpoints, projetos e pairing no mesmo arquivo | Quebrar por agregado (`SQLite.Messages`, `SQLite.Graph`, `SQLite.Memory`, `SQLite.Checkpoints`, `SQLite.Projects`, `SQLite.Pairing`) |
| `lib/pincer/adapters/tools/file_system.ex` | 1.654 | Confinamento de path, 16 ações, arquivo/zip-slip, edição ancorada/hashline, trash e listagem recursiva | Extrair `.Edit`, `.Archive`, `.Transfer` e `.Walk` |
| `packages/pincer_telegram/lib/pincer/channels/telegram.ex` | 1.614 | Polling/offset, parse de updates, comandos, menus/callbacks, mídia/transcrição e formatação | Extrair `.Poller`, `.Update`, `.Commands`, `.Menu`, `.Media` |
| `packages/pincer_discord/lib/pincer/channels/discord.ex` | 1.069 | Consumer Nostrum, slash commands, interações de menu, anexos e envio em chunks | Extrair `.Commands`, `.Interactions`, `.Attachments` |
| `lib/pincer/core/project_orchestrator.ex` | 943 | Wizard conversacional, dono da tabela ETS, sincronização com `ProjectFSM`, criação de branch git e renderização kanban | Separar `Project.Wizard`, `Project.BoardRenderer` e `Project.Store` |
| `lib/pincer/core/pairing.ex` | 913 | Geração/hash de códigos, ETS + DETS (`sessions/pairing_store.dets`), persistência SQLite e notificação PubSub | Separar `Pairing.Code`, `Pairing.Store` e `Pairing.Notifier` |
| `lib/pincer/core/session/server.ex` | 863 | Ciclo GenServer, correlação de tasks, ingestão de blackboard, debounce de input, comandos, PubSub e alinhamento | Extrair `Session.InputBuffer`, `Session.CommandDispatcher` e `Session.TaskCoordinator` |
| `lib/pincer/config.ex` | 831 | Load de `.env` + YAML, allowlist em `Application`, detecção de sandbox/storage e edição escalar de YAML | Separar `Config.Loader`, `Config.Applier` e `Config.YamlWriter` |
| `lib/pincer/adapters/connectors/mcp/manager.ex` | 743 | Ciclo de vida dos servidores MCP, descoberta, filtragem e despacho de ferramentas | Extrair registro/descoberta de ciclo de supervisão |
| `lib/pincer/core/llm/skills_sidecar_policy.ex` | 722 | Validação de flags `docker run`, mounts, envs e digest para sidecar de skills | Mover/renomear foco de argv Docker para política dedicada de sandbox |
| `lib/pincer/infra/sqlite.ex` | 694 | GenServer de conexão Exqlite, DDL/migração de schema, carregamento `sqlite-vec` e helpers de resolução de backend | Separar `SQLite.Schema` e `SQLite.VecLoader` |
| `packages/pincer_whatsapp/lib/pincer/channels/whatsapp.ex` | 659 | Bridge Go/Erlang, comandos, mídia e envio | Extrair handlers de comando e mídia |
| `lib/mix/tasks/pincer.onboard.ex` | 618 | Flags CLI, prompts interativos, escrita de `.env`, preflight e renderização de plano | Extrair prompter interativo e escritor de `.env` |
| `lib/pincer/core/onboard.ex` | 596 | Planejamento local/remoto, aplicação de plano, deep merge e serialização | Separar `.Plan`, `.Apply` e `.RemotePlan` |
| `lib/pincer/core/executor.ex` | 501 | Loop principal já enxuto via `Ctx`/`FallbackStrategy`, mas `run_stream/8`, `recover_empty_response/5` e `resolve_text_outcome/9` ainda carregam aridade alta | Extrair `Executor.StreamRunner` e encapsular argumentos no `Ctx` |

Outros módulos ainda acima de 400 LOC que merecem acompanhamento gradual: `lib/pincer/core/orchestration/archivist.ex` (600), `lib/pincer/core/memory/memory_recall.ex` (588), `lib/pincer/core/orchestration/sub_agent.ex` (586), `lib/pincer/core/introspection/kernel.ex` (557), `lib/pincer/adapters/tools/orchestrator.ex` (554), `lib/pincer/core/doctor.ex` (419), `lib/pincer/core/executor/tool_runner.ex` (418) e `lib/pincer/llm/client.ex` (415).

---

## 3. Code smells, inconsistências e higiene restante

### 3.1 Código não-idiomático e tratamento de erros

- **Blocos `rescue` amplos** (78 ocorrências em `lib/` e `packages/`):
  - `lib/pincer/core/executor/tool_runner.ex` (`run_tool/7`) captura qualquer exceção em `rescue e ->` e devolve status `:ok`, impedindo que crashes de tools contem como falhas consecutivas.
  - `lib/pincer/adapters/tools/workflow.ex` converte falhas internas em strings genéricas em múltiplos catch-alls.
  - `lib/pincer/core/executor.ex` envolve todo o consumo do stream em `rescue error in Protocol.UndefinedError`.
- **Fontes de verdade ainda duplicadas**:
  - `lib/pincer/core/ux.ex` mantém `@commands` (11 comandos), `@shortcut_routes` e `help_text/1` separados; `help_text/1` lista apenas 7 comandos, omitindo `/model`, `/reset`, `/think` e `/reasoning`.
  - `lib/pincer/core/project_orchestrator.ex` (`@type phase` com 5 estados) coexiste com `lib/pincer/core/project_fsm.ex`, exigindo sincronização manual entre ambos.
  - `lib/pincer/cli.ex` (214 LOC) ainda usa `System.halt/1` diretamente em fluxo de CLI, exigindo cuidado quando invocado a partir de tasks Mix.

### 3.2 Higiene de pacotes e manifests

- **Manifests de plugin divergentes**: há diferenças entre cópias em `priv/plugins/` e nos pacotes correspondentes (`packages/pincer_dingtalk/priv/pincer_plugin.yaml`, `packages/pincer_discord/priv/pincer_plugin.yaml`, `packages/pincer_feishu/priv/pincer_plugin.yaml`, `packages/pincer_line/priv/pincer_plugin.yaml` e `packages/pincer_slack/priv/pincer_plugin.yaml`). Um check automatizado de paridade evita drift.
- **Metadados repetidos nos pacotes**: os 25 `mix.exs` em `packages/` repetem versão, licença, links e estrutura; provedores baseados em `packages/pincer_openai_compat/lib/pincer/llm/providers/openai_compat.ex` ainda acumulam 31 retornos `:not_implemented` explícitos para capacidades opcionais (`transcribe_audio`/`generate_embedding`).

---

## 4. Suíte de testes e governança arquitetural

Métricas observadas em `test/` (327 arquivos `.exs`, 323 `*_test.exs`):

| Métrica | Valor observado |
|---|---|
| Arquivos `*_test.exs` em `test/` | 323 |
| Testes arquiteturais em `test/pincer/architecture/` | 26 |
| Arquivos com `async: true` / `async: false` | 172 / 142 |
| Arquivos com `Process.sleep` | 30 |
| Arquivos com `Application.ensure_all_started(:pincer)` | 16 |

Pontos de melhoria na suíte:
- Reduzir gradualmente chamadas a `Process.sleep` (30 arquivos) substituindo por sincronização explícita via `receive`, monitores ou mensagens determinísticas.
- Manter novos testes unitários isolados com `async: true` e sem boot completo da aplicação (`--no-start` / injeção de dependências), preservando o tempo rápido de `mix qa`.

---

## 5. Verificado e descartado como falso positivo

- **Criação dinâmica de átomos a partir de entrada não confiável**: não ocorre em `packages/`; as chamadas restantes em `lib/` operam sobre listas configuradas ou usam `String.to_existing_atom/1` (por exemplo em `lib/pincer/adapters/tools/args.ex`).
- **Uso de `Process.sleep` no loop principal do Executor**: `lib/pincer/core/executor.ex` não bloqueia com `Process.sleep`; o temporizador de ferramentas usa `Process.send_after/3` em `lib/pincer/adapters/tools/timer_server.ex`.

---

## 6. Próximos passos priorizados

1. **Quebrar os maiores módulos SRP** (§2): iniciar por `lib/pincer/adapters/storage/sqlite.ex`, `lib/pincer/adapters/tools/file_system.ex`, `packages/pincer_telegram/lib/pincer/channels/telegram.ex` e `lib/pincer/core/session/server.ex`.
2. **Enxugar `lib/pincer/config.ex` e `lib/pincer/core/executor.ex`** (§2): separar carregamento/aplicação/escrita YAML em `Config` e mover o stream runner do `Executor` usando `Ctx`.
3. **Alinhar `lib/pincer/core/ux.ex` e estreitar `rescue` em `tool_runner.ex`** (§3.1): gerar `help_text/1` a partir de `@commands` e contabilizar exceções de ferramentas como erro de execução.
4. **Higiene de pacotes e testes** (§3.2, §4): garantir paridade entre `priv/plugins/` e `packages/`, reduzir stubs `:not_implemented` e substituir `Process.sleep` nos testes restantes.
