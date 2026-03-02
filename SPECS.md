# SPECS.md - Documentação Técnica Pincer (Protocolo Batedor)

Este relatório consolida as especificações técnicas das bibliotecas essenciais para o projeto Pincer, extraídas da documentação oficial em https://hexdocs.pm em 2026-02-18.

---

## Convenção de Sprint (renumerada)
- IDs canônicos seguem `SPR-NNN` e alinham com branches `sprint/spr-001..`.
- Mapeamento legado:
  - `SPR-01..SPR-04` => `SPR-028`
  - `SPR-05..SPR-14` => `SPR-029`
  - `SPR-15` => `SPR-030`
  - `SPR-16` => `SPR-031`

---

## 0. Incremento 2026-02-22 (Onboard + DB em `./db`)

### Objetivo
- Entregar base de onboarding linux-style (`mix pincer.onboard`).
- Padronizar bancos SQLite em `./db`.

### Interfaces Públicas
```elixir
Pincer.Core.Onboard.defaults/0
Pincer.Core.Onboard.plan/1
Pincer.Core.Onboard.apply_plan/2
```

```bash
mix pincer.onboard
mix pincer.onboard --non-interactive --yes
mix pincer.onboard --non-interactive --db-path db/custom.db
```

### Critérios de aceite
1. `mix pincer.onboard --non-interactive --yes` cria `config.yaml`, `db/`, `sessions/`, `memory/`.
2. Config padrão aponta DB para `db/pincer_mvp.db`.
3. `config/dev.exs` e `config/test.exs` usam paths em `db/`.
4. Implementação coberta por testes em:
   - `test/pincer/core/onboard_test.exs`
   - `test/mix/tasks/pincer.onboard_test.exs`
   - `test/pincer/config/db_paths_test.exs`

### Erros amigáveis (incremento atual)
- Objetivo: mapear os erros mais comuns para mensagens claras ao usuário final.
- Interface:
  - `Pincer.Core.ErrorUX.friendly/2`
- Escopo inicial:
  - Erros HTTP de provedor (401/403/404/429/5xx)
  - Erros de rede (`timeout`, `econnrefused`, `nxdomain`)
  - Timeouts internos de processo
  - Erros de schema/db (`no such table`)
  - Erros de execução previsíveis (`:tool_loop`)
- Integração:
  - `Pincer.Session.Server` para `{:executor_failed, reason}`
  - `quick_assistant_reply/5` em fallback de erro
- Critério de aceite:
  - nenhum erro comum gera silêncio para usuário; sempre há mensagem de ação sugerida.

### Retry Policy v1 (incremento atual)
- Objetivo: manter backoff exponencial no `429` e estender retry para falhas transitórias.
- Regras:
  - Retry com backoff exponencial para:
    - `HTTP 408, 429, 500, 502, 503, 504`
    - `Req.TransportError` transitórios (`:timeout`, `:econnrefused`, `:closed`, `:enetunreach`, `:ehostunreach`, `:connect_timeout`)
  - Sem retry para erros definitivos (`400`, `401`, `403`, `404`, `422`).
  - Se `Retry-After` vier em `429/503`, respeitar valor (segundos ou HTTP-date) como base de espera.
  - Aplicar jitter no atraso para evitar thundering herd.
- Configuração runtime (`Application env`):
  - `:llm_retry` com chaves:
    - `:max_retries`
    - `:initial_backoff`
    - `:max_backoff`
    - `:max_elapsed_ms`
    - `:jitter_ratio`
- Testes:
  - retry em `503`
  - sem retry em `401`
  - retry em `Req.TransportError(:timeout)`
  - respeito a `Retry-After`
  - parada por deadline total (`max_elapsed_ms`)

### Resiliência de callbacks Telegram (incremento atual)
- Objetivo: impedir crash-loop do `UpdatesProvider` em callbacks inválidos ou erro de edição de mensagem.
- Escopo:
  - tratar `callback_query` sem `message/chat_id/message_id` sem exceção
  - tratar callback desconhecido com resposta amigável e botão `Menu`
  - se `edit_message_text` falhar, enviar fallback amigável ao usuário e seguir polling
- Critério de aceite:
  1. `UpdatesProvider` não encerra ao receber callback malformado.
  2. Callback desconhecido retorna mensagem de orientação para o usuário.
  3. Falha no `edit_message_text` não derruba polling; usuário recebe fallback.

### Governança de comandos/menu (C03 - incremento atual)
- Objetivo: centralizar no core a política de comandos registrados em canais (Telegram/Discord), com validação, deduplicação e limite por canal.
- Interface:
  - `Pincer.Core.UX.MenuPolicy.registerable_commands/2`
- Regras:
  - nomes normalizados para minúsculo;
  - nomes inválidos (regex por canal) são descartados;
  - comandos duplicados são descartados;
  - descrição vazia é descartada;
  - excesso acima do limite de canal é truncado com issue reportada.
- Limites v1:
  - Telegram: 100
  - Discord: 100
- Integração:
  - `Pincer.Channels.Telegram.register_commands/0`
  - `Pincer.Channels.Discord.register_commands/0`
- Critério de aceite:
  1. registro de comandos não falha por entradas inválidas/duplicadas;
  2. Telegram e Discord usam a mesma política no core;
  3. testes de política cobrem validação, dedupe e cap.

### Política de DM no core (SPR-028 / C06 - especificação)
- Objetivo: mover para o core a autorização de mensagens diretas (DM), com comportamento consistente entre canais.
- Interface (core):
  - `Pincer.Core.AccessPolicy.authorize_dm/3`
- Assinatura proposta:
```elixir
@spec authorize_dm(
  channel :: :telegram | :discord,
  sender_id :: String.t() | integer(),
  config :: map()
) ::
  {:allow, map()} |
  {:deny, %{mode: atom(), reason: atom(), user_message: String.t()}}
```
- Contrato de configuração por canal:
```yaml
channels:
  telegram:
    dm_policy:
      mode: "open"        # open | allowlist | disabled | pairing
      allow_from: []      # ex.: ["924255495", "77*", "*"]
```
- Regras v1:
  - `open`: permite qualquer DM;
  - `allowlist`: permite apenas IDs em `allow_from` (com suporte a `*` e prefixo `abc*`);
  - `disabled`: bloqueia DMs;
  - `pairing`: reservado para sprint futura de pairing (nesta sprint, bloqueia com mensagem clara).
- Integração v1:
  - Telegram: aplicar somente para `chat.type == "private"` antes de encaminhar para sessão.
  - Discord: aplicar somente para eventos DM (`guild_id == nil`) antes de encaminhar para sessão.
- Critérios de aceite:
  1. decisão de autorização fica no core (sem duplicação de regra por adapter);
  2. DMs bloqueadas retornam mensagem amigável e não entram no fluxo de sessão;
  3. testes cobrem `open`, `allowlist`, `disabled`, `pairing`, wildcard e fallback de config inválida.

### Registry de modelos (SPR-028 / C09 - especificação)
- Objetivo: centralizar no core um catálogo read-only de modelos por provider, com suporte a aliases e adição por configuração (sem hardcode por provider).
- Interface (core):
  - `Pincer.Core.Models.Registry.list_providers/1`
  - `Pincer.Core.Models.Registry.list_models/2`
  - `Pincer.Core.Models.Registry.resolve_model/3`
- Assinaturas propostas:
```elixir
@spec list_providers(registry :: map() | nil) :: [%{id: String.t(), name: String.t()}]
@spec list_models(provider_id :: String.t(), registry :: map() | nil) :: [String.t()]
@spec resolve_model(provider_id :: String.t(), model_or_alias :: String.t(), registry :: map() | nil) ::
  {:ok, String.t()} | {:error, :unknown_provider | :unknown_model}
```
- Contrato de configuração aceito por provider (`:llm_providers`):
```elixir
%{
  "z_ai" => %{
    default_model: "glm-4.7",
    models: ["glm-4.7", "glm-4.5"],
    model_aliases: %{"default" => "glm-4.7", "fast" => "glm-4.5"}
  }
}
```
- Regras v1:
  - `list_providers/1` gera lista estável ordenada por `id`;
  - `list_models/2` inclui `default_model` e `models`, remove duplicados e entradas inválidas;
  - `resolve_model/3` aceita id real ou alias e falha explicitamente para provider/modelo desconhecido.
- Integração v1:
  - `Pincer.LLM.Client.list_providers/0` delega ao registry de core;
  - `Pincer.LLM.Client.list_models/1` delega ao registry de core.
- Critérios de aceite:
  1. nenhum provider/modelo depende de lista hardcoded no código;
  2. alias lookup funciona sem alterar adapters de canal;
  3. testes cobrem provider inválido, alias válido, dedupe e ordenação estável.

### Streaming preview/finalização (SPR-028 / C17 - especificação)
- Objetivo: garantir pré-visualização incremental com cursor e finalização in-place sem mensagem final duplicada.
- Interface (core):
  - `Pincer.Core.StreamingPolicy.initial_state/0`
  - `Pincer.Core.StreamingPolicy.on_partial/4`
  - `Pincer.Core.StreamingPolicy.on_final/2`
- Assinaturas propostas:
```elixir
@spec initial_state() :: %{message_id: integer() | nil, buffer: String.t(), last_update: integer()}
@spec on_partial(state :: map(), token :: String.t(), now_ms :: integer(), opts :: keyword()) ::
  {new_state :: map(), action :: :noop | {:render_preview, String.t()}}
@spec on_final(state :: map(), final_text :: String.t()) ::
  {reset_state :: map(), action :: {:send_final, String.t()} | {:edit_final, integer(), String.t()} | :noop}
```
- Regras v1:
  - partial sempre acumula no buffer;
  - preview usa cursor `▌` apenas durante streaming;
  - final nunca contém cursor;
  - se já existe mensagem de preview (`message_id`), final deve editar a mesma mensagem;
  - se não existe preview, final deve enviar uma única mensagem final.
- Integração v1:
  - `Pincer.Channels.Telegram.Session` usa policy para decidir `send_message` vs `update_message` no fluxo parcial/final.
  - `Pincer.Channels.Discord.Session` idem.
- Critérios de aceite:
  1. cenário com partial + final realiza `1 send + N edits` (sem segundo send final);
  2. cenário só com final realiza `1 send` sem cursor;
  3. Telegram e Discord compartilham a mesma política de core.

### Hardening operacional + daemon systemd (SPR-029 / C12 - especificação)
- Objetivo:
  - endurecer o loop de polling do Telegram para degradação de rede/API sem crash-loop;
  - padronizar operação como daemon em VPS via `systemd` com baseline de segurança.
- Interfaces/artefatos públicos:
  - `Pincer.Channels.Telegram.UpdatesProvider.next_poll_interval/1`
  - `infrastructure/systemd/pincer.service`
  - `infrastructure/systemd/pincer.env.example`
  - `docs/systemd.md`
- Regras de hardening v1 (polling):
  - falha de polling incrementa contador de falhas no estado;
  - intervalo de polling usa backoff exponencial com teto;
  - sucesso de polling zera contador de falhas;
  - offset só avança quando há updates válidos;
  - nenhuma exceção de processamento de update encerra o provider.
- Regras de hardening v1 (daemon):
  - `Restart=always` com `RestartSec` curto;
  - execução com `MIX_ENV=prod`;
  - canal default operacional no serviço: Telegram;
  - restrições básicas de sistema habilitadas (`NoNewPrivileges`, `PrivateTmp`, `ProtectSystem`, `ProtectHome`).
- Critérios de aceite:
  1. testes cobrem intervalo de backoff, incremento/reset de falhas e avanço de offset;
  2. configuração default mantém Discord desabilitado (`config.yaml`);
  3. serviço `systemd` consegue subir/derrubar processo de forma reproduzível com guia operacional.

### Hardening de execução MCP no core (SPR-029 / C12 - especificação)
- Objetivo:
  - impedir falhas em cascata no executor quando o `MCP.Manager` estiver lento ou indisponível.
- Interface/contrato:
  - `Pincer.Adapters.NativeToolRegistry.list_tools/0` nunca deve propagar exit por timeout de `MCP.Manager`.
- Regras:
  - em timeout/exit de `MCPManager.get_all_tools/0`, retornar apenas ferramentas nativas;
  - registrar warning de diagnóstico, sem derrubar fluxo de execução;
  - manter formato de retorno OpenAI-tools inalterado.
- Critérios de aceite:
  1. teste cobre fallback para ferramentas nativas quando MCP falha por timeout;
  2. teste cobre caminho feliz com merge de ferramentas nativas + MCP;
  3. executor não falha por `GenServer.call(... :get_tools ...)` durante degradação MCP.

### Hardening de streaming + orçamento de contexto (SPR-029 / C12 - especificação)
- Objetivo:
  - impedir falhas de protocolo no caminho de streaming (`Enumerable`/`Collectable`);
  - reduzir erro `400` por `max_tokens` excessivo em contexto longo.
- Escopo:
  - `Pincer.LLM.Client` valida resposta de stream e faz fallback seguro para single-shot quando necessário;
  - `Pincer.LLM.Providers.OpenAICompat` usa budget de completion tokens com limite por contexto estimado;
  - `Pincer.Core.ErrorUX` mapeia overflow de contexto para ação clara (`/reset`, trocar modelo).
- Critérios de aceite:
  1. stream inválido não derruba executor e retorna fallback consistente;
  2. corpo enviado para OpenAI-compat sempre contém limite explícito de tokens (cap seguro);
  3. erro de contexto grande retorna mensagem amigável orientando limpeza/troca de modelo.

### Error taxonomy + telemetria (SPR-029 / C12 - especificação)
- Objetivo:
  - padronizar classificação de erros operacionais em classes estáveis;
  - emitir telemetria por classe para monitoramento e diagnóstico;
  - reduzir ruído de logs promovendo `warning` para falhas esperadas/transitórias.
- Interfaces (core):
  - `Pincer.Core.ErrorClass.classify/1`
  - `Pincer.Core.Telemetry.emit_error/2`
  - `Pincer.Core.Telemetry.emit_retry/2`
- Classes mínimas v1:
  - `http_401`, `http_403`, `http_404`, `http_429`, `http_5xx`
  - `transport_timeout`, `transport_connect`, `transport_dns`
  - `process_timeout`, `retry_timeout`, `tool_loop`, `db_schema`
  - `stream_payload`, `context_overflow`, `internal`, `unknown`
- Eventos de telemetria:
  - `[:pincer, :error]` com `%{count: 1}` e metadata de classe/escopo/componente;
  - `[:pincer, :retry]` com `%{count: 1, wait_ms: integer}` e metadata de classe.
- Integração v1:
  - `Pincer.LLM.Client` em retry/falha final;
  - `Pincer.Session.Server` em `executor_failed` e erro de quick-reply;
  - `Telegram.UpdatesProvider` em erro de polling.
- Critérios de aceite:
  1. testes cobrem classificação mínima e emissão de eventos;
  2. retries/falhas finais disparam eventos com classe consistente;
  3. logs de falha transitória de polling deixam de ser `error` contínuo.

### DX macros + aliases de fluxo (SPR-029 / DX - especificação)
- Objetivo:
  - reduzir boilerplate de testes e padronizar comandos de rotina para desenvolvimento.
- Escopo:
  - macros utilitárias para testes/flows (`with_app_env`, `assert_ok`);
  - aliases `mix` para execução rápida de qualidade (`qa`, `test.quick`, `sprint.check`).
- Critérios de aceite:
  1. macros cobertas por testes de unidade;
  2. aliases presentes em `Mix.Project.config/0`;
  3. fluxo de QA rápido executável com um único comando.

### Paridade de ergonomia Discord + fallback de interação (SPR-029 / C04+C05 - especificação)
- Objetivo:
  - fechar lacuna de ergonomia do Discord em relação ao baseline do Telegram;
  - impedir silencios/quebras em `custom_id` desconhecido ou malformado.
- Escopo:
  - Discord deve aceitar texto simples `Menu` (sem `/`) como atalho de ajuda;
  - fluxo `/models` deve expor um affordance explícito de retorno ao menu;
  - `INTERACTION_CREATE` com `custom_id` desconhecido deve responder orientação amigável.
- Interface de core (UX):
  - `Pincer.Core.UX.unknown_interaction_hint/0`
- Integração v1:
  - `Pincer.Channels.Discord.Consumer`:
    - roteia `"Menu"` para mesmo tratamento de `/menu`;
    - adiciona botão `Menu` no fluxo de seleção de provider/modelo;
    - trata ações desconhecidas de `custom_id` sem exceção.
- Critérios de aceite:
  1. Discord não ignora `Menu` textual em mensagens comuns;
  2. interações desconhecidas retornam resposta com orientação (`/menu`) em vez de crash/silêncio;
  3. testes cobrem paridade de menu e fallback de interação.

### Portas de core: onboarding, capability discovery, user menu (SPR-029 / arquitetura - especificação)
- Objetivo:
  - tornar explícitos os contratos de domínio para onboarding, descoberta de capacidades e menu de interação.
- Interfaces (ports):
  - `Pincer.Core.Ports.Onboarding`
    - `defaults/0`
    - `plan/1`
    - `apply_plan/2`
  - `Pincer.Core.Ports.CapabilityDiscovery`
    - `list_capabilities/1`
    - `find_capability/2`
  - `Pincer.Core.Ports.UserMenu`
    - `commands/0`
    - `help_text/1`
    - `unknown_command_hint/0`
    - `unknown_interaction_hint/0`
- Implementação v1:
  - `Pincer.Core.Onboard` declara comportamento `Onboarding`;
  - `Pincer.Core.UX` declara comportamento `UserMenu`;
  - novo módulo `Pincer.Core.CapabilityDiscovery` implementa `CapabilityDiscovery`.
- Critérios de aceite:
  1. portas existem como contratos formais no core;
  2. módulos de core aderem aos contratos via `@behaviour`;
  3. testes cobrem descoberta mínima (`onboard`, `menu`, `models`, `dm_policy`).

### Testes de contrato para adapters de canal e providers (SPR-029 / qualidade - especificação)
- Objetivo:
  - cercar regressão estrutural garantindo que adapters continuem aderentes às interfaces hexagonais.
- Escopo:
  - contratos para adapters de canal (`Telegram`, `Discord`) contra `Pincer.Channel`;
  - contratos para providers LLM contra `Pincer.LLM.Provider`.
- Regras:
  - teste deve falhar se callback obrigatório não estiver exportado;
  - teste deve validar presença de comportamento declarado.
- Critérios de aceite:
  1. nova suíte de contrato passa no CI local;
  2. mudanças futuras em adapters quebram cedo quando violarem interface;
  3. cobertura de contrato não depende de rede externa.

### Onboard orientado a capabilities (SPR-029 / C01 - especificação)
- Objetivo:
  - modelar onboarding como conjunto de capabilities do core (estilo OpenClaw), sem acoplamento a canal/provider.
- Interface (core):
  - `Pincer.Core.Onboard.available_capabilities/0`
  - `Pincer.Core.Onboard.plan/2` com `capabilities: [...]`
- Interface (CLI adapter):
  - `mix pincer.onboard --capabilities workspace_dirs,config_yaml,memory_file`
- Regras v1:
  - capability IDs aceitos:
    - `workspace_dirs`
    - `memory_file`
    - `config_yaml`
  - seleção inválida deve falhar explicitamente com erro de validação;
  - `plan/1` mantém compatibilidade e usa todas as capabilities por padrão.
- Critérios de aceite:
  1. onboarding continua deterministicamente reproduzível;
  2. seleção de capabilities funciona no core e no mix task;
  3. testes cobrem caminho feliz e capability inválida.

### Política unificada de retry/transient (SPR-029 / C10+C12 - especificação)
- Objetivo:
  - centralizar no core as decisões de retry e transiência operacional;
  - remover listas de erro duplicadas em `LLM.Client`, `Session.Server` e `Telegram.UpdatesProvider`.
- Interface (core):
  - `Pincer.Core.RetryPolicy.retryable?/1`
  - `Pincer.Core.RetryPolicy.transient?/1`
  - `Pincer.Core.RetryPolicy.retry_after_ms/3`
  - `Pincer.Core.RetryPolicy.parse_retry_after/2`
- Regras v1:
  - `retryable?/1` cobre exatamente classes transitórias já aceitas no cliente LLM:
    - `HTTP 408/429/500/502/503/504`
    - `Req.TransportError` transitório (`timeout`, `connect_timeout`, `econnrefused`, `closed`, `enetunreach`, `ehostunreach`)
    - `{:timeout, _}`
  - `transient?/1` deriva de classificação estável (`ErrorClass`) para uso de logging/telemetria;
  - `retry_after_ms/3` lê metadados de `429/503` (`retry_after_ms`/`retry_after`) e limita ao deadline global.
- Integração v1:
  - `Pincer.LLM.Client` delega retryability e parsing de `Retry-After` para `Pincer.Core.RetryPolicy`;
  - `Pincer.Session.Server` e `Pincer.Channels.Telegram.UpdatesProvider` usam `transient?/1` para decidir `warning` vs `error`.
- Critérios de aceite:
  1. não há mais listas de classes transitórias duplicadas nos adapters citados;
  2. suites de retry e telemetria existentes continuam verdes sem regressão comportamental;
  3. novos testes do core cobrem matriz mínima (`retryable?/1`, `transient?/1`, `retry_after_ms/3`).

### Política determinística de failover (SPR-030 / C10+C12 - especificação)
- Objetivo:
  - transformar classes de erro em ações determinísticas de execução (`retry`/`fallback`/`stop`);
  - evitar decisões ad-hoc de troca de modelo/provider no `LLM.Client`.
- Documento detalhado:
  - `docs/SPECS/FAILOVER_POLICY_V1.md`
- Interface (core):
  - `Pincer.Core.LLM.FailoverPolicy.initial_state/1`
  - `Pincer.Core.LLM.FailoverPolicy.next_action/2`
  - `Pincer.Core.LLM.FailoverPolicy.summarize_attempts/1`
- Assinaturas propostas:
```elixir
@type failover_action ::
  :retry_same |
  {:fallback_model, provider :: String.t(), model :: String.t()} |
  {:fallback_provider, provider :: String.t(), model :: String.t()} |
  :stop

@spec initial_state(keyword()) :: map()
@spec next_action(reason :: term(), state :: map()) :: {failover_action(), map()}
@spec summarize_attempts(state :: map()) :: %{attempts: [map()], terminal_reason: term() | nil}
```
- Regras v1:
  - classes de erro retryable (`RetryPolicy.retryable?/1`) iniciam com `:retry_same` até o teto local de tentativas;
  - após teto local, policy tenta `fallback_model` dentro do mesmo provider (se houver candidato não tentado);
  - sem candidato local, tenta `fallback_provider` com próximo provider elegível;
  - classes terminais (`http_401`, `http_403`, `http_404`, schema/config inválida) retornam `:stop`;
  - todas as decisões devem ser reproduzíveis (sem aleatoriedade) dado o mesmo estado de entrada.
- Integração v1:
  - `Pincer.LLM.Client` delega decisão de próxima ação para `FailoverPolicy.next_action/2`;
  - telemetria de tentativa/fallback mantém classe de erro (`ErrorClass`) e ação decidida.
- Critérios de aceite:
  1. matriz de decisão por classe de erro está coberta por testes de unidade no core;
  2. `LLM.Client` não contém branch local de failover por classe;
  3. execução retorna resumo de tentativas útil para diagnóstico (`summarize_attempts/1`).

### Cooldown cross-request por provider (SPR-031 / C11 - especificação)
- Objetivo:
  - evitar thrashing entre requests sucessivos quando um provider está degradado;
  - compartilhar estado temporal de indisponibilidade por classe de erro.
- Documento detalhado:
  - `docs/SPECS/COOLDOWN_STORE_V1.md`
- Interface (core):
  - `Pincer.Core.LLM.CooldownStore.cooldown_provider/2`
  - `Pincer.Core.LLM.CooldownStore.cooling_down?/1`
  - `Pincer.Core.LLM.CooldownStore.available_providers/1`
  - `Pincer.Core.LLM.CooldownStore.clear_provider/1`
- Regras v1:
  - cooldown aplicado apenas para classes transitórias de infraestrutura/rate limit (`http_429`, `http_5xx`, `transport_*`, `process_timeout`);
  - duração por classe configurável via `:pincer, :llm_cooldown`;
  - provider em cooldown é evitado na seleção de fallback de provider;
  - em sucesso, provider utilizado é removido de cooldown.
- Integração v1:
  - `Pincer.LLM.Client` aplica cooldown no provider que falhou antes de decidir fallback;
  - `Pincer.LLM.Client` pode rotear requests default para provider alternativo elegível quando o default estiver em cooldown;
  - `Pincer.Core.LLM.FailoverPolicy` ignora providers em cooldown ao buscar `fallback_provider`.
- Critérios de aceite:
  1. testes do core cobrem aplicar/expirar/limpar cooldown e filtro de providers elegíveis;
2. teste de integração comprova efeito cross-request (segunda request evita provider em cooldown);
3. suíte LLM existente continua verde sem regressão.

### Doctor operacional (SPR-034 / C02 - especificação)
- Objetivo:
  - introduzir diagnóstico operacional central para startup/configuração segura;
  - consolidar validação de `config.yaml`, tokens de canais habilitados e postura de DM policy.
- Interface (core):
  - `Pincer.Core.Doctor.run/1`
- Interface (CLI adapter):
  - `mix pincer.doctor`
  - `mix pincer.doctor --strict`
  - `mix pincer.doctor --config path/to/config.yaml`
- Regras v1:
  - `config.yaml` inexistente ou inválido é erro bloqueante;
  - canal habilitado com `token_env` ausente no ambiente é erro bloqueante;
  - `dm_policy` em `open`/ausente/inválido gera warning de segurança;
  - saída padronizada com status (`ok`, `warn`, `error`) e contagem por severidade.
- Critérios de aceite:
  1. testes RED cobrem config inválida, token ausente e policy insegura;
  2. `mix pincer.doctor` falha com `Mix.Error` quando houver erros bloqueantes;
  3. modo `--strict` falha quando houver warnings.

### Pairing approval workflow (SPR-035 / C07 - especificação)
- Objetivo:
  - habilitar pairing real para DM quando policy estiver em `pairing`;
  - impedir replay de código por expiração, consumo único e limite de tentativas.
- Interface (core):
  - `Pincer.Core.Pairing.issue_code/3`
  - `Pincer.Core.Pairing.approve_code/4`
  - `Pincer.Core.Pairing.reject_code/4`
  - `Pincer.Core.Pairing.paired?/2`
  - `Pincer.Core.Pairing.reset/0` (suporte a testes)
- Integração (core/channel):
  - `Pincer.Core.AccessPolicy.authorize_dm/3`:
    - em `pairing`, sender pareado é liberado;
    - sender não pareado recebe código de pairing e negação amigável.
  - Telegram/Discord:
    - comando `/pair <codigo>` para concluir aprovação de pairing.
- Regras v1:
  - código tem janela de validade (`ttl_ms`) e número máximo de tentativas;
  - aprovação consome o código e promove sender para estado `paired`;
  - rejeição consome o código sem promover sender;
  - tentativas inválidas acima do limite invalidam o pending code.
- Critérios de aceite:
  1. testes cobrem emissão, aprovação, rejeição, expiração e bloqueio de replay;
2. `AccessPolicy` em modo `pairing` permite DM após aprovação válida;
3. comandos de canal `/pair` retornam mensagens amigáveis para estados (`not_pending`, `expired`, `invalid_code`).

### Security audit command (SPR-036 / C18 - especificação)
- Objetivo:
  - auditar postura de segurança operacional de canais e gateway;
  - detectar rapidamente riscos de autenticação ausente e superfície de DM insegura.
- Interface (core):
  - `Pincer.Core.SecurityAudit.run/1`
- Interface (CLI adapter):
  - `mix pincer.security_audit`
  - `mix pincer.security_audit --strict`
  - `mix pincer.security_audit --config path/to/config.yaml`
- Regras v1:
  - config inválida/inexistente gera erro bloqueante;
  - canal habilitado sem token efetivo em `token_env` gera erro bloqueante;
  - `dm_policy` insegura (`open`, ausente ou inválida) gera warning;
  - bind de gateway em interface global (`0.0.0.0`, `::`) gera warning.
- Critérios de aceite:
  1. testes cobrem warnings para policy aberta e bind arriscado;
  2. testes cobrem erro para auth ausente em canal habilitado;
  3. task falha em `--strict` quando houver warnings.

### Auth profile rotation (SPR-037 / C13 - especificação)
- Objetivo:
  - habilitar cadeia determinística de credenciais por provider/profile;
  - aplicar rotação por cooldown sem quebrar providers legados sem cadeia auth declarada.
- Interface (core):
  - `Pincer.Core.AuthProfiles.resolve/3`
  - `Pincer.Core.AuthProfiles.cooldown_profile/4`
  - `Pincer.Core.AuthProfiles.cooling_down?/2`
  - `Pincer.Core.AuthProfiles.clear_profile/2`
- Integração (LLM client):
  - `Pincer.LLM.Client.chat_completion/2` e `stream_completion/2` resolvem profile antes da chamada ao adapter;
  - falhas terminais aplicam cooldown ao profile selecionado;
  - sucesso limpa cooldown do profile selecionado.
- Regras v1:
  - `auth_profiles` define precedência por `name` + `env_key`;
  - opção `auth_profile` prioriza profile específico quando disponível;
  - se provider declara cadeia auth (`auth_profiles`/`env_key`) sem credenciais válidas, retorna `{:error, :missing_credentials}`;
  - se todos os perfis com credencial válida estiverem em cooldown, retorna `{:error, :all_profiles_cooling_down}`;
  - se provider não declara cadeia auth, mantém fluxo legado (sem bloqueio por credencial ausente).
- Critérios de aceite:
  1. testes cobrem precedência padrão, perfil em cooldown e erro de credencial ausente;
  2. testes cobrem compatibilidade legado para provider sem `auth_profiles`/`env_key`;
  3. suites de retry/failover/telemetria permanecem verdes.

### Two-layer memory formalization (SPR-038 / C14 - especificação)
- Objetivo:
  - formalizar memória em duas camadas com papéis explícitos:
    - `MEMORY.md`: memória curada e consolidada;
    - `HISTORY.md`: trilha estruturada de sessões recentes.
  - garantir consolidação determinística por janela, sem duplicação de entradas.
- Interface (core):
  - `Pincer.Core.Memory.append_history/2`
  - `Pincer.Core.Memory.consolidate_window/1`
  - `Pincer.Core.Memory.record_session/2`
- Regras v1:
  - `append_history/2` escreve bloco estruturado em `HISTORY.md` com digest estável;
  - mesma sessão/conteúdo não gera bloco duplicado (idempotência por digest);
  - `consolidate_window/1` mantém somente as `N` entradas mais recentes em `HISTORY.md`;
  - entradas deslocadas para fora da janela são registradas em `MEMORY.md` com marcador estável (`[HIST:<digest>]`) para evitar duplicação.
- Integração v1:
  - `Pincer.Orchestration.Archivist` registra sessão em `HISTORY.md` e aplica consolidação após leitura do log;
  - onboarding passa a provisionar também `HISTORY.md`.
- Critérios de aceite:
  1. testes cobrem append estruturado no histórico;
  2. testes cobrem idempotência de append;
  3. testes cobrem consolidação por janela (`HISTORY.md` reduzido + `MEMORY.md` com resumo único dos itens deslocados).

### MCP HTTP/SSE transport (SPR-039 / C15 - especificação)
- Objetivo:
  - suportar transporte MCP sobre HTTP streamable/SSE além de `stdio`;
  - permitir headers custom por servidor para autenticação e tenancy.
- Interface (transport):
  - `Pincer.Connectors.MCP.Transports.HTTP.connect/1`
  - `Pincer.Connectors.MCP.Transports.HTTP.send_message/2`
  - `Pincer.Connectors.MCP.Transports.HTTP.close/1`
- Interface (client/manager):
  - `Pincer.Connectors.MCP.Client` deve aceitar mensagens de transporte genéricas (`{:mcp_transport, map}`), não apenas eventos de `Port`;
  - `Pincer.Connectors.MCP.Manager` deve montar opções por servidor respeitando `transport` + `headers`.
- Regras v1:
  - `transport: "http"` (ou módulo explícito) seleciona transporte HTTP;
  - `headers` aceitam map/list e são propagados para requisições;
  - resposta HTTP válida é encaminhada ao owner como mensagem MCP para correlação por `id`;
  - fallback/default permanece `stdio`, sem regressão.
- Critérios de aceite:
  1. testes cobrem envio HTTP com headers custom e forwarding da resposta;
  2. testes cobrem `Client` operando com transporte não-stdio;
  3. testes cobrem `Manager` gerando opts corretos para `stdio` e `http`.

### Skills governance and install gating (SPR-040 / C16 - especificação)
- Objetivo:
  - formalizar descoberta/instalação de skills com política explícita de segurança;
  - bloquear instalação fora de sandbox e fontes não confiáveis.
- Interface (core):
  - `Pincer.Core.Skills.discover/1`
  - `Pincer.Core.Skills.install/2`
- Interface (adapter):
  - `Pincer.Adapters.SkillsRegistry.Local.list_skills/1`
  - `Pincer.Adapters.SkillsRegistry.Local.fetch_skill/2`
- Regras v1:
  - instalação exige `source` permitido por allowlist de host;
  - checksum precisa estar no formato `sha256:<64-hex>`;
  - `expected_checksum` opcional deve casar exatamente com checksum do registry;
  - destino de instalação deve permanecer dentro de `sandbox_root` (sem path traversal);
  - registry adapter local lê catálogo declarativo via options/app env.
- Critérios de aceite:
  1. testes cobrem adapter de registry (list/fetch/not_found);
  2. testes cobrem bloqueio de source não confiável e mismatch de checksum;
  3. testes cobrem garantia de sandbox path e instalação bem-sucedida.

### Callback/interaction payload policy hardening (SPR-041 / C05 - especificação)
- Objetivo:
  - centralizar construção e parsing de payloads de interação para Telegram/Discord;
  - impedir que IDs malformados ou oversized gerem crash/silêncio nos adapters;
  - manter fallback amigável consistente quando payload não for processável.
- Interface (core):
  - `Pincer.Core.ChannelInteractionPolicy.provider_selector_id/2`
  - `Pincer.Core.ChannelInteractionPolicy.model_selector_id/3`
  - `Pincer.Core.ChannelInteractionPolicy.back_to_providers_id/1`
  - `Pincer.Core.ChannelInteractionPolicy.menu_id/1`
  - `Pincer.Core.ChannelInteractionPolicy.parse/2`
- Regras v1:
  - limites por canal:
    - Telegram `callback_data`: `64` bytes;
    - Discord `custom_id`: `100` bytes;
  - geração de payload acima do limite retorna erro explícito (`{:error, :payload_too_large}`);
  - parsing aceita apenas ações conhecidas (`select_provider`, `select_model`, `back_to_providers`, `show_menu`);
  - payload com shape inválido, campos vazios, tipo inválido ou acima do limite retorna erro de validação;
  - adapters devem tratar erro de validação com resposta amigável (sem exceção).
- Critérios de aceite:
  1. testes do core cobrem geração/parsing válido e rejeição de oversized/malformed;
  2. Telegram ignora payload inválido sem derrubar poller e mantém fallback de orientação;
  3. Discord trata `INTERACTION_CREATE` malformado (ex.: sem `data.custom_id`) sem crash e responde guidance.

### Onboarding preflight + safe existing-config merge (SPR-042 / C01 - especificação)
- Objetivo:
  - validar inconsistências críticas antes de aplicar onboarding;
  - impedir combinações inválidas de flags quando onboarding é limitado por `--capabilities`;
  - preservar configurações existentes durante onboarding não-interativo.
- Interface (core):
  - `Pincer.Core.Onboard.preflight/1`
  - `Pincer.Core.Onboard.merge_config/2`
- Interface (CLI adapter):
  - `mix pincer.onboard` deve executar preflight antes de `apply_plan/2`.
- Regras v1:
  - `preflight/1` deve falhar com hints quando:
    - `database.database` for inválido (`""`, absoluto, ou path traversal com `..`);
    - provider default (`llm.provider`) estiver ausente/vazio;
    - model default do provider estiver ausente/vazio.
  - quando `config.yaml` existir, onboarding deve carregar e fazer merge seguro com defaults (sem apagar chaves custom);
  - combinações inválidas:
    - usar `--db-path`, `--provider` ou `--model` sem capability `config_yaml` deve falhar com erro explícito.
- Critérios de aceite:
  1. testes de core cobrem preflight válido/inválido com hints e merge profundo determinístico;
  2. testes do mix task cobrem falha de matriz de flags com mensagem clara;
  3. testes do mix task cobrem preservação de seções custom em `config.yaml` existente.

### MCP HTTP streamable/SSE lifecycle parity (SPR-043 / C15 - especificação)
- Objetivo:
  - ampliar transporte MCP HTTP para respostas streamáveis (`text/event-stream`);
  - manter compatibilidade com resposta HTTP JSON direta;
  - formalizar fechamento seguro de recursos do transporte HTTP.
- Interface (transport):
  - `Pincer.Connectors.MCP.Transports.HTTP.send_message/2` deve suportar:
    - corpo JSON único (atual);
    - corpo SSE com múltiplos eventos `data: ...` contendo JSON-RPC.
  - `Pincer.Connectors.MCP.Transports.HTTP.close/1` deve executar cleanup opcional quando disponível.
- Regras v1:
  - em resposta `2xx` com `content-type` contendo `text/event-stream`, o transporte:
    - faz parse dos eventos SSE;
    - ignora evento `data: [DONE]`;
    - encaminha mensagens JSON válidas ao owner como `{:mcp_transport, [msg1, msg2, ...]}`.
  - payload SSE inválido deve retornar erro explícito (`{:error, {:invalid_sse_data, ...}}`);
  - `close/1` deve ser idempotente e não levantar exceções.
- Critérios de aceite:
  1. testes cobrem parse/forward de múltiplos eventos SSE;
  2. testes cobrem falha em SSE malformado;
  3. testes cobrem caminho de close com callback de cleanup.

### Skills install trust-boundary hardening (SPR-044 / C16 - especificação)
- Objetivo:
  - reforçar boundary de segurança na instalação de skills;
  - reduzir risco de instalação acidental ou fonte ambígua/não segura;
  - bloquear roots de instalação potencialmente inseguras.
- Interface (core):
  - `Pincer.Core.Skills.install/2` com política explícita de autorização.
- Regras v1:
  - instalação exige opt-in explícito via `allow_install: true`;
  - `source` deve ser URL com host e schema permitido (default: `https`);
  - allowlist de fonte aceita:
    - host exato (`trusted.example.com`);
    - wildcard de sufixo (`*.trusted.example.com`);
  - `sandbox_root` não pode ser symlink;
  - checks de checksum e confinamento de path no sandbox continuam obrigatórios.
- Critérios de aceite:
  1. testes cobrem bloqueio sem `allow_install: true`;
  2. testes cobrem bloqueio para `http://` e aceitação de wildcard de host;
  3. testes cobrem bloqueio de `sandbox_root` symlink.

### MCP HTTP long-lived stream resilience (SPR-046 / C15 - especificação)
- Objetivo:
  - endurecer transporte HTTP MCP para streams SSE de longa duração;
  - reduzir perda de sessão por desconexão transitória com reconexão controlada;
  - evitar ruído de payload por heartbeats e replay de eventos após reconnect.
- Interface (transport):
  - `Pincer.Connectors.MCP.Transports.HTTP.connect/1`
  - `Pincer.Connectors.MCP.Transports.HTTP.send_message/2`
- Novas opções de conexão (v1):
  - `:max_reconnect_attempts` (default `3`)
  - `:initial_backoff_ms` (default `200`)
  - `:max_backoff_ms` (default `2_000`)
  - `:sleep_fn` (injeção para testes)
- Regras v1:
  - eventos SSE heartbeat/keepalive (`event: heartbeat|ping`, comentários `: ...`) são ignorados;
  - stream SSE encerrado sem sentinel `data: [DONE]` é tratado como interrupção transitória e pode reconectar;
  - reconexão usa backoff exponencial com teto;
  - em reconexão, payload duplicado já entregue não deve ser reenviado ao owner;
  - erros não transitórios (ex.: SSE inválido, `4xx` terminal) falham sem loop de reconexão.
- Critérios de aceite:
  1. testes cobrem ignore de heartbeat sem impacto no payload útil;
  2. testes cobrem reconnect com backoff e entrega final bem-sucedida;
  3. testes cobrem dedupe de replay após reconnect e parada ao exceder tentativas.

### Onboarding remoto/assistido + preflight de ambiente expandido (SPR-045 / C01 - especificação)
- Objetivo:
  - fechar gap restante do `C01` com um fluxo assistido para bootstrap remoto;
  - antecipar riscos operacionais com checklist de ambiente antes do deploy.
- Documento detalhado:
  - `docs/SPECS/ONBOARD_REMOTE_ASSISTED_V1.md`
- Interface (core):
  - `Pincer.Core.Onboard.assisted_preflight/2`
  - `Pincer.Core.Onboard.remote_assisted_plan/2`
- Interface (CLI adapter):
  - `mix pincer.onboard --mode remote --non-interactive --remote-host <host>`
  - flags novas:
    - `--mode local|remote`
    - `--remote-host`
    - `--remote-user`
    - `--remote-path`
- Regras v1:
  - modo `remote` exige `--remote-host`;
  - `remote_path` deve ser absoluto e não conter `..`;
  - `assisted_preflight/2` reporta warnings com hint para:
    - token ausente em `token_env` de canais habilitados;
    - credencial ausente do provider LLM atual (`env_key`);
    - comando MCP ausente no PATH (`npx`, etc.).
  - preflight estrutural existente (`preflight/1`) continua bloqueante para erros de configuração.
- Critérios de aceite:
  1. modo remoto imprime plano determinístico de bootstrap e não executa `apply_plan/2`;
  2. modo remoto não cria/escreve arquivos locais de onboarding;
  3. checklist expandido mostra warnings acionáveis para lacunas de ambiente.

### Resiliência concorrente de callbacks/interactions (SPR-047 / C05 - especificação)
- Objetivo:
  - endurecer adapters de canal contra rajadas de callbacks/interactions malformados;
  - garantir estabilidade do hot-swap de modelo sob troca concorrente durante janela de backoff.
- Interface (adapters):
  - `Pincer.Channels.Telegram.UpdatesProvider.handle_info/2` (via `safe_process_update/1`);
  - `Pincer.Channels.Discord.Consumer.handle_event/1`;
  - `Pincer.Channels.Discord.Consumer.send_interaction_response/2` (com validação de envelope).
- Interface (LLM core/client):
  - `Pincer.LLM.Client.do_request_with_retry/13` para evento `{:model_changed, provider, model}`.
- Regras v1:
  - flood de callbacks malformados não pode derrubar o poller Telegram;
  - flood de interactions malformadas sem `id/token` válido deve ser ignorado com log de warning, sem tentativa de chamada à API Discord;
  - quando múltiplos `model_changed` chegam durante backoff, a troca aplicada deve ser a mais recente (last-write-wins) antes do retry imediato.
- Critérios de aceite:
  1. testes cobrem lote grande de callbacks malformados no Telegram com processo vivo após poll;
  2. testes cobrem interações malformadas no Discord sem `create_interaction_response/3` quando envelope é inválido;
  3. testes cobrem hot-swap concorrente durante backoff com resultado final refletindo a última troca.

### Streaming incremental consistente por SessionScope (SPR-048 / C17 - especificação)
- Objetivo:
  - garantir entrega de `agent_partial`/`agent_response` em Telegram e Discord quando `SessionScopePolicy` resolve sessão dinâmica (ex.: `*_main`);
  - eliminar mismatch entre tópico PubSub assinado pelo worker de canal e `session_id` efetivo usado pelo `Session.Server`.
- Interface (adapters):
  - `Pincer.Channels.Telegram.Session.ensure_started/2`
  - `Pincer.Channels.Discord.Session.ensure_started/2`
  - `Pincer.Channels.Telegram.UpdatesProvider.do_process_message/3`
  - `Pincer.Channels.Discord.Consumer.handle_event/1` (MESSAGE_CREATE path)
- Regras v1:
  - worker de sessão deve suportar bind/rebind explícito para `session_id`;
  - ao rebind, worker desinscreve do tópico antigo, inscreve no novo e reseta estado de streaming local (buffer/message_id);
  - chamada de `ensure_started` no path de entrada de mensagem deve informar o `session_id` roteado por policy.
- Critérios de aceite:
  1. testes cobrem rebind de worker Telegram para `telegram_main` com entrega de resposta no tópico novo;
  2. testes cobrem rebind de worker Discord para `discord_main` com entrega de resposta no tópico novo;
  3. suites de sessão/canais permanecem verdes sem regressão do fluxo atual.

### Carregamento dinâmico de MCP `config.json` (SPR-049 / operabilidade - especificação)
- Objetivo:
  - permitir descoberta de servidores MCP a partir de arquivos `config.json` no padrão Cursor/Claude Desktop;
  - reduzir acoplamento do bootstrap MCP ao `config.yaml` local;
  - manter previsibilidade operacional com precedência explícita para configuração estática do projeto.
- Interface (MCP adapter layer):
  - `Pincer.Connectors.MCP.ConfigLoader.discover_servers/1`
  - `Pincer.Connectors.MCP.ConfigLoader.merge_static_and_dynamic/2`
  - `Pincer.Connectors.MCP.Manager.resolve_servers_config/1`
- Regras v1:
  - fontes de leitura dinâmicas vêm de `:pincer, :mcp_dynamic_config_paths` (quando configurado) ou de caminhos default conhecidos;
  - formatos aceitos:
    - `%{"mcpServers" => %{...}}` (padrão Cursor/Claude Desktop);
    - `%{"mcp" => %{"servers" => %{...}}}` (variante compatível com Pincer);
  - entradas inválidas (arquivo ausente, JSON inválido, shape inválido) não derrubam o manager e geram fallback seguro para `%{}`;
  - servidores com `disabled: true` são ignorados no merge dinâmico;
  - merge final é determinístico: `static_servers` (do `config.yaml` carregado) sobrescreve nomes conflitantes vindos de config dinâmica.
- Critérios de aceite:
  1. testes cobrem parse de `mcpServers` e `mcp.servers`;
  2. testes cobrem fallback sem crash para arquivos inválidos/ausentes;
  3. testes cobrem precedência estática no merge final consumido pelo `MCP.Manager`.

---

## 1. ExGram (v0.57.0)
Biblioteca principal para construção do bot Telegram.

### Configurações (config.exs)
```elixir
config :ex_gram,
  token: "SEU_TOKEN",
  adapter: ExGram.Adapter.Req, # Uso do Req conforme solicitado
  json_engine: Jason

# Configuração de Polling (Resiliência)
config :ex_gram, :polling,
  allowed_updates: ["message", "callback_query", "edited_message"],
  delete_webhook: true
```

### Estruturas Principais (Structs)
- **%ExGram.Cnt{}**: Contexto da atualização. Contém `message`, `update`, `extra`, `answers`.
- **%ExGram.Model.Update{}**: Objeto de atualização do Telegram.
- **%ExGram.Model.Message{}**: Objeto de mensagem recebida.

### Callbacks e Handlers
O framework utiliza o comportamento `ExGram.Bot`.
```elixir
defmodule MyBot.Bot do
  use ExGram.Bot, name: :my_bot

  # Callback de inicialização
  def init(opts) do
    # Configurações iniciais do bot
    :ok
  end

  # Handlers de mensagens
  def handle({:command, "start", _msg}, context), do: answer(context, "Olá!")
  def handle({:text, text, _msg}, context), do: answer(context, "Você disse: #{text}")
  def handle({:callback_query, query}, context), do: :ok
end
```

---

## 2. Req (v0.5.17)
Cliente HTTP moderno e resiliente.

### Uso Essencial
```elixir
# Requisição básica com retry automático
Req.get!("https://api.telegram.org/...", retry: :safe_transient, max_retries: 5)

# Configuração de instância reutilizável
client = Req.new(base_url: "https://api.github.com", auth: {:bearer, token})
Req.get!(client, url: "/repos/...")
```

### Funcionalidades de Resiliência
- **Retry**: `:safe_transient` (padrão) retira erros 408/429/5xx e timeouts.
- **Steps**: Permite injetar lógica antes/depois da requisição (ex: logging, auth).

---

## 3. Ecto (v3.13.5)
Camada de persistência e validação de dados.

### Componentes Principais
- **Ecto.Repo**: Wrapper do banco de dados (`all`, `get`, `insert`, `update`, `delete`).
- **Ecto.Schema**: Mapeamento de tabelas para structs Elixir.
- **Ecto.Changeset**: Validação e cast de dados.
- **Ecto.Query**: DSL para consultas seguras.

### Exemplo de Schema para Resiliência
```elixir
defmodule Pincer.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :telegram_id, :integer
    field :username, :string
    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:telegram_id, :username])
    |> validate_required([:telegram_id])
    |> unique_constraint(:telegram_id)
  end
end
```

---

## 4. YamlElixir (v2.12.1)
Parser de arquivos YAML para configurações dinâmicas.

### Uso Essencial
```elixir
# Leitura de arquivo
{:ok, config} = YamlElixir.read_from_file("config.yml")

# Leitura com suporte a átomos (usar com cuidado)
YamlElixir.read_from_string(yaml_string, atoms: true)

# Suporte a Sigil
import YamlElixir.Sigil
config = ~y"""
  bot_name: PincerBot
  features:
    - logger
    - persistence
"""
```

---

## Notas de Implementação para o Pincer
1. **Integração ExGram + Req**: Definir explicitamente `config :ex_gram, adapter: ExGram.Adapter.Req`.
2. **Resiliência de Rede**: Aproveitar o sistema de retries do `Req` dentro do adaptador do `ExGram`.
3. **Persistência**: Utilizar `Ecto.Repo.transaction` para operações críticas de estado do bot.
4. **Configuração Externa**: Usar `YamlElixir` para carregar mensagens e parâmetros de comportamento sem necessidade de recompilação.

### Hardening de Superfície de Ferramentas (SPR-050 / Security)
- Objetivo:
  - bloquear escapes por symlink no `FileSystem`;
  - endurecer `SafeShell` para impedir caminhos absolutos/fora de workspace em comandos whitelisted;
  - reforçar `Web` contra SSRF por hostname ambíguo e evitar crash em IPv6.
- Interface afetada:
  - `Pincer.Tools.FileSystem.execute/1`
  - `Pincer.Tools.SafeShell.execute/1`
  - `Pincer.Tools.Web.execute/1`
- Regras v1:
  - `FileSystem`:
    - valida confinamento por `Path.expand` e também por `realpath` do ancestral existente mais próximo;
    - se o ancestral real resolver fora do root do workspace, retorna erro de acesso negado;
    - mantém contrato read-only (`list`/`read`) e não faz follow inseguro para fora da jail.
  - `SafeShell`:
    - comandos com argumento de caminho absoluto (`/`), home expansion (`~`) ou traversal (`..`) exigem aprovação;
    - endurecimento aplica para `cat/head/tail/du -sh` e também para argumentos genéricos de `ls/find`.
  - `Web`:
    - parsing de IP privado não pode lançar exceção para IPv6/IPv4-mapped IPv6;
    - hostnames com ponto final (`localhost.`) devem ser tratados como host equivalente (`localhost`);
    - host que resolve para faixa interna/metadata é bloqueado antes do fetch.
- Critérios de aceite:
  1. teste de regressão bloqueia leitura por symlink (`workspace/link -> /etc/passwd`);
  2. teste de regressão bloqueia `SafeShell` com `cat /etc/passwd` e `ls /etc`;
  3. teste de regressão para `Web` com `http://[::ffff:127.0.0.1]/` retorna erro controlado (sem crash);
  4. suíte focada de segurança passa sem regressão no comportamento seguro já coberto.

### Baseline A11y de Canais (SPR-051 / UX-A11y)
- Objetivo:
  - consolidar rotas de menu acessíveis no core;
  - permitir navegação por teclado com comandos explícitos com e sem `/`;
  - manter mensagens de orientação curtas para leitores de tela.
- Interface afetada:
  - `Pincer.Core.UX.help_text/1`
  - `Pincer.Core.UX.unknown_command_hint/0`
  - `Pincer.Core.UX.unknown_interaction_hint/0`
  - `Pincer.Core.UX.resolve_shortcut/1` (nova)
  - `Pincer.Channels.Telegram.UpdatesProvider` (roteamento de shortcut textual)
  - `Pincer.Channels.Discord.Consumer` (roteamento de shortcut textual)
- Regras v1:
  - `resolve_shortcut/1` aceita atalhos com e sem `/` para:
    - `menu`, `status`, `models`, `ping`;
    - mantém compatibilidade com `Menu` (botão/label) e aliases de ajuda (`/help`, `/commands`).
  - atalhos inválidos não devem capturar mensagens livres; seguem para fluxo normal da sessão.
  - `help_text/1` deve mencionar explicitamente as rotas textuais (com e sem `/`).
  - hints de erro/desconhecido devem permanecer curtos e com ação única clara (`/menu`).
- Critérios de aceite:
  1. `Pincer.Core.UX.resolve_shortcut/1` resolve corretamente atalhos válidos e rejeita ruído;
  2. Telegram roteia `status` (sem `/`) para o mesmo comportamento de `/status`;
  3. Discord roteia `status` (sem `/`) para o mesmo comportamento de `/status`;
  4. suíte focada de UX/canais permanece verde sem regressão.

### Front de Segurança (SPR-052 / Security)
- Objetivo:
  - reduzir risco de prompt injection indireta no `Web.fetch`;
  - bloquear bypass por line-continuation/multiline no `SafeShell`;
  - ampliar `SecurityAudit` com flags perigosas de configuração.
- Interface afetada:
  - `Pincer.Tools.Web.execute/1`
  - `Pincer.Tools.WebVisibility.sanitize_html/1` (novo)
  - `Pincer.Tools.WebVisibility.strip_invisible_unicode/1` (novo)
  - `Pincer.Tools.SafeShell.execute/1`
  - `Pincer.Core.SecurityAudit.run/1`
- Regras v1:
  - `Web`:
    - remover nós ocultos por `hidden`, `aria-hidden=true`, classes de ocultação comuns e estilos inline típicos de ocultação;
    - remover comentários HTML antes de extrair texto;
    - remover caracteres Unicode invisíveis usados em ataques de injeção.
  - `SafeShell`:
    - comandos com `\\\n`, `\\\r\n` ou quebra de linha direta (`\n`/`\r`) exigem aprovação;
    - manter comportamento atual para whitelist e demais validações.
  - `SecurityAudit`:
    - alertar quando flags perigosas estiverem habilitadas (ex.: `gateway.control_ui.allow_insecure_auth`, `gateway.control_ui.dangerously_disable_device_auth`, `hooks.*.allow_unsafe_external_content`, `tools.exec.apply_patch.workspace_only=false`);
    - considerar variações de chave snake_case/camelCase para compatibilidade.
- Critérios de aceite:
  1. teste de unidade valida sanitização de conteúdo oculto e remoção de Unicode invisível;
  2. teste de regressão bloqueia line-continuation/multiline no `SafeShell`;
  3. `SecurityAudit` retorna `warn` ao detectar flags perigosas;
  4. suíte focada de segurança permanece verde sem regressões existentes.

### Restrict To Workspace (SPR-053 / Security Runtime)
- Objetivo:
  - aplicar política de confinamento de workspace para shell e leitura de arquivos;
  - fechar bypass pós-aprovação no executor com política fail-closed;
  - expor postura no `SecurityAudit`.
- Interface afetada:
  - `Pincer.Core.WorkspaceGuard.confine_path/2` (novo)
  - `Pincer.Tools.FileSystem.execute/1`
  - `Pincer.Tools.SafeShell.execute/1`
  - `Pincer.Tools.SafeShell.approved_command_allowed?/2` (novo)
  - `Pincer.Core.Executor` (fluxo de aprovação de comando)
  - `Pincer.Core.SecurityAudit.run/1`
- Regras v1:
  - `WorkspaceGuard` valida:
    - bloqueio de null-byte e traversal (`..`);
    - confinamento por `Path.expand` + validação de ancestral real para bloquear escape por symlink.
  - `FileSystem` usa o guard centralizado para path jail.
  - `SafeShell` valida argumentos de path com guard centralizado (bloqueio de escape por symlink em path relativo).
  - Executor:
    - ao receber aprovação de comando, revalida comando por política de workspace antes de executar `run_command`;
    - em modo restrito, comandos reprovados retornam erro explícito (sem execução).
  - `SecurityAudit`:
    - sinaliza como erro quando `tools.restrict_to_workspace=false`.
- Critérios de aceite:
  1. regressão cobre bloqueio de symlink escape no `SafeShell`;
  2. regressão cobre bloqueio no executor de comando aprovado fora da política;
  3. `SecurityAudit` reporta erro para `tools.restrict_to_workspace=false`;
  4. suíte focada de segurança/executor permanece verde.

### Runtime de Skills Isolado (SPR-054 / Sidecar Hardened Baseline)
- Objetivo:
  - criar gate fail-closed para `skills_sidecar` antes de iniciar cliente MCP;
  - impedir ativação de sidecar sem isolamento mínimo obrigatório;
  - expor postura do sidecar no `SecurityAudit`.
- Documento de referência:
  - `docs/SPECS/SIDECAR_RUNTIME_HARDENED_V2.md`
- Interface afetada:
  - `Pincer.Connectors.MCP.SkillsSidecarPolicy.validate/1` (novo)
  - `Pincer.Connectors.MCP.Manager.resolve_servers_config/2`
  - `Pincer.Core.SecurityAudit.run/1`
- Regras v1:
  - política aplica-se somente ao servidor `mcp.servers.skills_sidecar`;
  - sidecar deve usar `docker run` com isolamento mínimo:
    - `--read-only`
    - `--network=none`
    - `--cap-drop=ALL`
    - `--pids-limit` (ou `--pids-limit=<n>`)
    - `--memory` (ou `--memory=<value>`)
    - `--cpus` (ou `--cpus=<value>`)
    - `--user` (não-root)
    - `-v ...:/sandbox` (mount explícito do sandbox)
  - quando `skills_sidecar` estiver inválido, `MCP.Manager` deve remover esse servidor da configuração resolvida (sem derrubar os demais);
  - `SecurityAudit` deve:
    - emitir `:ok` quando sidecar estiver ausente (não habilitado) ou presente com isolamento válido;
    - emitir `:error` quando sidecar estiver presente com isolamento inválido.
- Critérios de aceite:
  1. testes unitários validam aceitação de sidecar hardened e rejeição de sidecar inseguro;
  2. `resolve_servers_config/2` não retorna `skills_sidecar` quando policy falha;
  3. `SecurityAudit` reporta erro explícito para sidecar inseguro;
  4. suíte focada (policy/manager/audit) permanece verde.

### Runtime de Skills Isolado (SPR-055 / Sidecar Execution Audit)
- Objetivo:
  - emitir auditoria mínima por execução de tool no `skills_sidecar`;
  - capturar status e duração sem quebrar contrato atual de `MCP.Manager.execute_tool/2`;
  - fornecer telemetria estável para observabilidade e incident response.
- Interface afetada:
  - `Pincer.Connectors.MCP.SidecarAudit.emit/5` (novo)
  - `Pincer.Connectors.MCP.SidecarAudit.status_from_result/1` (novo)
  - `Pincer.Connectors.MCP.Manager.audit_sidecar_result/5` (novo, `@doc false`)
  - `Pincer.Connectors.MCP.Manager.handle_call({:execute, ...})`
- Regras v1:
  - somente chamadas roteadas para `server_name == "skills_sidecar"` geram evento de auditoria;
  - evento deve incluir no mínimo:
    - tool chamada
    - skill id (baseline: `skills_sidecar`)
    - skill version (baseline: `unknown`)
    - duração em ms
    - status (`:ok`, `:error`, `:timeout`, `:blocked`)
  - resultado funcional de `execute_tool/2` deve permanecer inalterado (audit side-effect only).
- Critérios de aceite:
  1. status é classificado corretamente para respostas `{:ok, _}`, `{:error, :timeout}` e erros genéricos;
  2. `audit_sidecar_result/5` audita sidecar e não audita outros servidores;
  3. evento de telemetria é emitido com métricas/metadados mínimos esperados;
  4. suíte focada de audit/manager permanece verde.

### Runtime de Skills Isolado (SPR-056 / Sidecar Env Secrets Denylist)
- Objetivo:
  - bloquear vazamento de credenciais host->sidecar via `mcp.servers.skills_sidecar.env`;
  - aplicar política fail-closed no bootstrap do sidecar;
  - reaproveitar validação central no `SecurityAudit`.
- Interface afetada:
  - `Pincer.Connectors.MCP.SkillsSidecarPolicy.validate/1`
  - `Pincer.Connectors.MCP.SkillsSidecarPolicy.sensitive_env_keys/0` (novo)
  - `Pincer.Connectors.MCP.Manager.resolve_servers_config/2`
  - `Pincer.Core.SecurityAudit.run/1` (via policy já integrada)
- Regras v1:
  - `skills_sidecar` deve rejeitar env com chaves sensíveis (denylist explícita), por exemplo:
    - `TELEGRAM_BOT_TOKEN`, `DISCORD_BOT_TOKEN`, `SLACK_BOT_TOKEN`
    - `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`
    - `GITHUB_TOKEN`, `GITHUB_PERSONAL_ACCESS_TOKEN`
    - `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`
    - `DATABASE_URL`
  - suporte a formatos de `env`:
    - map (`%{"KEY" => "value"}`)
    - lista de tuplas (`[{"KEY", "value"}]`)
    - lista `KEY=VALUE` (string)
  - quando houver chave sensível, `skills_sidecar` não deve ser ativado em `resolve_servers_config/2`.
- Critérios de aceite:
  1. policy rejeita `skills_sidecar` com env sensível e informa quais chaves foram bloqueadas;
  2. policy aceita env não sensível;
  3. `resolve_servers_config/2` remove sidecar com env sensível;
  4. `SecurityAudit` reporta erro para sidecar com env sensível.

### Runtime de Skills Isolado (SPR-057 / Sidecar Tool Timeout Hard)
- Objetivo:
  - aplicar timeout hard para execução de tools no `skills_sidecar`;
  - evitar bloqueio prolongado do `MCP.Manager` em chamadas de skill travadas;
  - classificar timeout para auditoria de execução já existente.
- Interface afetada:
  - `Pincer.Connectors.MCP.Manager.call_tool_with_timeout/4` (novo, `@doc false`)
  - `Pincer.Connectors.MCP.Manager.handle_call({:execute, ...})`
  - `Pincer.Connectors.MCP.SidecarAudit.status_from_result/1` (reuso para `{:error, :timeout}`)
- Regras v1:
  - apenas `skills_sidecar` usa execução com timeout hard; outros servidores mantêm fluxo atual;
  - em timeout:
    - retornar `{:error, :timeout}`;
    - encerrar processo de chamada (`Task.shutdown(..., :brutal_kill)`) para não reter worker;
  - resultado funcional de chamadas bem-sucedidas permanece inalterado.
- Critérios de aceite:
  1. helper de timeout retorna sucesso quando execução termina dentro do limite;
  2. helper retorna `{:error, :timeout}` quando execução excede o limite;
  3. helper não aplica timeout hard para servidores que não são `skills_sidecar`;
  4. suíte focada de manager/audit permanece verde.

### Runtime de Skills Isolado (SPR-058 / Sidecar Mount Target Allowlist)
- Objetivo:
  - restringir targets de mount no sidecar para reduzir superfície de escape no container;
  - impedir bind mounts inesperados para paths além de `/sandbox` e `/tmp`;
  - manter validação centralizada na policy de sidecar.
- Interface afetada:
  - `Pincer.Connectors.MCP.SkillsSidecarPolicy.validate/1`
  - `Pincer.Connectors.MCP.Manager.resolve_servers_config/2` (reuso da policy)
  - `Pincer.Core.SecurityAudit.run/1` (reuso da policy já integrada)
- Regras v1:
  - mounts de `skills_sidecar` só podem apontar para targets:
    - `/sandbox`
    - `/tmp`
  - qualquer target diferente deve falhar com erro explícito e bloquear ativação do sidecar.
- Critérios de aceite:
  1. policy rejeita mount target fora da allowlist e informa targets bloqueados;
  2. policy aceita configuração com `/sandbox` e `/tmp`;
  3. `resolve_servers_config/2` remove sidecar inválido por mount target;
  4. `SecurityAudit` reporta erro para sidecar com mount target inválido.

### Runtime de Skills Isolado (SPR-059 / Sidecar Dangerous Docker Flags Denylist)
- Objetivo:
  - bloquear flags Docker de alto risco na execução do `skills_sidecar`;
  - evitar escalada de privilégio e quebra de isolamento por configuração permissiva;
  - manter validação fail-closed centralizada na policy.
- Interface afetada:
  - `Pincer.Connectors.MCP.SkillsSidecarPolicy.validate/1`
  - `Pincer.Connectors.MCP.Manager.resolve_servers_config/2` (reuso da policy)
  - `Pincer.Core.SecurityAudit.run/1` (reuso da policy já integrada)
- Regras v1:
  - sidecar deve rejeitar flags perigosas como:
    - `--privileged`
    - `--cap-add`
    - `--device`
    - `--pid=host`
    - `--ipc=host`
    - `--security-opt=*unconfined*`
  - quando houver flag perigosa, sidecar não deve ser ativado.
- Critérios de aceite:
  1. policy rejeita flags perigosas e informa quais foram detectadas;
  2. `resolve_servers_config/2` remove sidecar com flag perigosa;
  3. `SecurityAudit` reporta erro para sidecar com flag perigosa;
  4. suíte focada de policy/manager/audit permanece verde.

### Runtime de Skills Isolado (SPR-060 / Sidecar Image Digest Pinning)
- Objetivo:
  - impor imutabilidade de imagem do `skills_sidecar` para reduzir risco de supply-chain;
  - evitar uso de tags mutáveis (`:latest`, sem digest) no runtime isolado;
  - manter validação fail-closed centralizada na policy.
- Interface afetada:
  - `Pincer.Connectors.MCP.SkillsSidecarPolicy.validate/1`
  - `Pincer.Connectors.MCP.Manager.resolve_servers_config/2` (reuso da policy)
  - `Pincer.Core.SecurityAudit.run/1` (reuso da policy já integrada)
- Regras v1:
  - imagem do `skills_sidecar` deve estar pinada por digest:
    - formato esperado: `repo@sha256:<64-hex>`
  - sidecar com imagem não-pinada deve ser bloqueado.
- Critérios de aceite:
  1. policy rejeita imagem não-pinada;
  2. policy aceita imagem com digest pinado válido;
  3. `resolve_servers_config/2` remove sidecar com imagem não-pinada;
  4. `SecurityAudit` reporta erro para sidecar com imagem não-pinada.

### Runtime de Skills Isolado (SPR-061 / Sandbox Mount Source Confinement)
- Objetivo:
  - impedir bind-mount de paths sensíveis do host no target `/sandbox`;
  - reduzir risco de exfiltração/escala lateral por configuração de mount permissiva;
  - manter validação fail-closed centralizada na policy.
- Interface afetada:
  - `Pincer.Connectors.MCP.SkillsSidecarPolicy.validate/1`
  - `Pincer.Connectors.MCP.Manager.resolve_servers_config/2` (reuso da policy)
  - `Pincer.Core.SecurityAudit.run/1` (reuso da policy já integrada)
- Regras v1:
  - mount com target `/sandbox` deve usar source relativo do workspace (ex.: `./skills`);
  - mount com target `/sandbox` deve bloquear:
    - source absoluto (ex.: `/etc:/sandbox`);
    - source volume nomeado (ex.: `pincer-skills:/sandbox`);
    - source com `..` (traversal).
- Critérios de aceite:
  1. policy rejeita source inválido para target `/sandbox` e informa quais sources foram bloqueados;
  2. `resolve_servers_config/2` remove sidecar com source inválido em `/sandbox`;
  3. `SecurityAudit` reporta erro para sidecar com source inválido em `/sandbox`;
  4. sidecar hardened com `./skills:/sandbox` permanece aceito.

### Runtime de Skills Isolado (SPR-062 / Tmp Mount Source Guard)
- Objetivo:
  - impedir bind-mount de paths do host no target opcional `/tmp`;
  - reduzir risco de exposição de arquivos/soquetes sensíveis via `/tmp` no container;
  - manter validação fail-closed centralizada na policy.
- Interface afetada:
  - `Pincer.Connectors.MCP.SkillsSidecarPolicy.validate/1`
  - `Pincer.Connectors.MCP.Manager.resolve_servers_config/2` (reuso da policy)
  - `Pincer.Core.SecurityAudit.run/1` (reuso da policy já integrada)
- Regras v1:
  - mount com target `/tmp` é opcional;
  - quando presente, source deve ser volume nomeado (ex.: `pincer-tmp:/tmp`);
  - mount com target `/tmp` deve bloquear source path (absoluto/relativo/traversal), ex.:
    - `/var/run/docker.sock:/tmp`
    - `./tmp:/tmp`
    - `../tmp:/tmp`
- Critérios de aceite:
  1. policy rejeita source inválido para target `/tmp` e informa quais sources foram bloqueados;
  2. `resolve_servers_config/2` remove sidecar com source inválido em `/tmp`;
  3. `SecurityAudit` reporta erro para sidecar com source inválido em `/tmp`;
  4. sidecar permanece aceito para source volume nomeado em `/tmp`.

### Runtime de Skills Isolado (SPR-063 / Env Args Secret Guard)
- Objetivo:
  - eliminar bypass de secrets via flags `-e/--env` em `docker args`;
  - manter bloqueio de credenciais host->sidecar consistente entre `env` no config e args CLI;
  - preservar validação fail-closed centralizada na policy.
- Interface afetada:
  - `Pincer.Connectors.MCP.SkillsSidecarPolicy.validate/1`
  - `Pincer.Connectors.MCP.Manager.resolve_servers_config/2` (reuso da policy)
  - `Pincer.Core.SecurityAudit.run/1` (reuso da policy já integrada)
- Regras v1:
  - denylist de chaves sensíveis deve considerar também variáveis passadas em args Docker:
    - `-e KEY=VALUE`
    - `--env KEY=VALUE`
    - `--env`, `KEY=VALUE` (token seguinte)
  - sidecar com chave sensível em args deve ser bloqueado com erro explícito.
- Critérios de aceite:
  1. policy rejeita secrets em args `-e/--env` e reporta as chaves bloqueadas;
  2. `resolve_servers_config/2` remove sidecar com secrets em args;
  3. `SecurityAudit` reporta erro para sidecar com secrets em args;
  4. sidecar permanece aceito quando args `-e/--env` usam somente chaves não sensíveis.

### Runtime de Skills Isolado (SPR-064 / Mount Flag Bypass Guard)
- Objetivo:
  - bloquear bypass de política de mounts via flag `--mount`;
  - manter superfície de montagem restrita ao parser auditado (`-v/--volume`);
  - preservar validação fail-closed centralizada na policy.
- Interface afetada:
  - `Pincer.Connectors.MCP.SkillsSidecarPolicy.validate/1`
  - `Pincer.Connectors.MCP.Manager.resolve_servers_config/2` (reuso da policy)
  - `Pincer.Core.SecurityAudit.run/1` (reuso da policy já integrada)
- Regras v1:
  - sidecar deve rejeitar uso de:
    - `--mount`
    - `--mount=...`
  - rejeição deve ocorrer com erro explícito em `dangerous_docker_flags`.
- Critérios de aceite:
  1. policy rejeita `--mount`/`--mount=` e reporta a flag bloqueada;
  2. `resolve_servers_config/2` remove sidecar com `--mount`;
  3. `SecurityAudit` reporta erro para sidecar com `--mount`;
  4. sidecar hardened sem `--mount` permanece aceito.

### Runtime de Skills Isolado (SPR-065 / Env File Flag Guard)
- Objetivo:
  - bloquear bypass de política de segredos via `--env-file`;
  - impedir injeção indireta de credenciais host->container por arquivo de ambiente externo;
  - preservar validação fail-closed centralizada na policy.
- Interface afetada:
  - `Pincer.Connectors.MCP.SkillsSidecarPolicy.validate/1`
  - `Pincer.Connectors.MCP.Manager.resolve_servers_config/2` (reuso da policy)
  - `Pincer.Core.SecurityAudit.run/1` (reuso da policy já integrada)
- Regras v1:
  - sidecar deve rejeitar uso de:
    - `--env-file`
    - `--env-file=...`
  - rejeição deve ocorrer com erro explícito em `dangerous_docker_flags`.
- Critérios de aceite:
  1. policy rejeita `--env-file`/`--env-file=` e reporta a flag bloqueada;
  2. `resolve_servers_config/2` remove sidecar com `--env-file`;
  3. `SecurityAudit` reporta erro para sidecar com `--env-file`;
  4. sidecar hardened sem `--env-file` permanece aceito.

### Runtime de Skills Isolado (SPR-066 / Required Flag Override Guard)
- Objetivo:
  - bloquear bypass por override tardio de flags obrigatórias no `docker run`;
  - validar o valor efetivo (última ocorrência) de flags críticas de isolamento;
  - preservar validação fail-closed centralizada na policy.
- Interface afetada:
  - `Pincer.Connectors.MCP.SkillsSidecarPolicy.validate/1`
  - `Pincer.Connectors.MCP.Manager.resolve_servers_config/2` (reuso da policy)
  - `Pincer.Core.SecurityAudit.run/1` (reuso da policy já integrada)
- Regras v1:
  - validação de flags obrigatórias com valor deve considerar valor efetivo (última ocorrência), por exemplo:
    - `--network=none`
    - `--cap-drop=ALL`
    - `--pids-limit`
    - `--memory`
    - `--cpus`
    - `--user`
  - se houver override final inseguro (ex.: `--network=none ... --network=host`), sidecar deve ser bloqueado.
- Critérios de aceite:
  1. policy rejeita configuração com override final inseguro em flag obrigatória;
  2. `resolve_servers_config/2` remove sidecar com override final inseguro;
  3. `SecurityAudit` reporta erro para sidecar com override final inseguro;
  4. sidecar hardened sem override inseguro permanece aceito.

### CLI Interativo com Histórico Persistente (SPR-067)
- Objetivo:
  - fechar o item de backlog do `mix pincer.chat` com histórico persistente de entradas;
  - oferecer comandos de histórico para inspeção e limpeza sem sair do loop;
  - manter compatibilidade com comandos já existentes (`/q`, `/quit`, `/clear`).
- Interfaces públicas:
  - `Pincer.CLI.process_command/1`
  - `Pincer.CLI.History.append/2`
  - `Pincer.CLI.History.recent/2`
  - `Pincer.CLI.History.clear/1`
- Regras v1:
  - cada entrada de usuário enviada ao backend pelo CLI deve ser persistida em arquivo local;
  - comando `/history` exibe os últimos 10 itens;
  - comando `/history N` exibe os últimos `N` itens (`N` inteiro positivo);
  - comando `/history clear` limpa o histórico persistido;
  - comando inválido de histórico (ex.: `/history abc`) faz fallback para o padrão de 10 itens.
- Critérios de aceite:
  1. histórico persiste entre execuções (`append` + `recent`);
  2. limpeza de histórico funciona via comando dedicado e API;
  3. parsing de comando mantém comportamento legado para `/q`, `/quit`, `/clear`;
  4. cobertura de testes para parsing e ciclo append/recent/clear.

### Webhook Universal (SPR-068 / Ingestão v1)
- Objetivo:
  - habilitar integração universal de eventos externos via canal `Webhook` sem acoplamento a provider específico;
  - padronizar ingestão em sessão Pincer com suporte a autenticação por token e dedupe de retries;
  - manter contrato receive-only do canal (sem requisito de outbound).
- Interfaces públicas:
  - `Pincer.Channels.Webhook.start_link/1`
  - `Pincer.Channels.Webhook.ingest/2`
- Regras v1:
  - payload deve conter texto útil em formato flexível (`text`, `content`, `prompt`, estruturas aninhadas como `message.text`/`event.text`);
  - resolução de sessão:
    - `session_id` explícito no payload tem precedência;
    - `session_mode: "per_sender"` deriva `session_id` por `source + sender_id`;
    - fallback para `default_session_id` quando não há identificador de remetente;
  - autenticação obrigatória via `token_env`; sem token configurado, o canal não inicia (fail-closed);
  - dedupe por `event_id` deve ignorar retry duplicado sem reenfileirar no `Session.Server`;
  - integração principal: `Session.Supervisor.start_session/1` (quando necessário) + `Session.Server.process_input/2`.
- Critérios de aceite:
  1. webhook válido é aceito e roteado para sessão correta;
  2. webhook sem token válido é rejeitado;
  3. retry com mesmo `event_id` retorna status de duplicado e não processa de novo;
  4. payload sem conteúdo textual útil falha com erro explícito.

### Notificações Inteligentes de Progresso (SPR-069 / Sub-Agente)
- Objetivo:
  - tornar progresso de sub-agentes visível de forma útil ao usuário final;
  - reduzir spam de status repetido com dedupe determinístico por agente/etapa;
  - limitar avaliação via LLM do blackboard a casos realmente ambíguos.
- Interfaces públicas:
  - `Pincer.Core.SubAgentProgress.notifications/2`
  - `Pincer.Session.Server.handle_info(:heartbeat, state)` (integração)
  - `Pincer.Channels.Telegram.Session.handle_info({:agent_status, text}, state)` (entrega em canal)
- Regras v1:
  - classificar mensagens de blackboard por padrão:
    - `Started with goal:` -> notificação de início (uma vez por agente);
    - `Using tool:` -> notificação apenas quando a ferramenta muda;
    - `FINISHED:` -> notificação terminal de sucesso (uma vez);
    - `FAILED:` -> notificação terminal de erro (uma vez);
  - mensagens não classificadas marcam `needs_review=true` para fallback de decisão por LLM;
  - no heartbeat:
    - publicar `agent_status` para notificações determinísticas geradas pela policy;
    - executar `evaluate_blackboard_update` somente se `needs_review=true` e sessão estiver `:idle`.
- Critérios de aceite:
  1. início/ferramenta/finalização não geram spam repetido por mensagens duplicadas;
  2. canais que exibem `agent_status` passam a refletir progresso real dos sub-agentes;
  3. Telegram exibe `agent_status` (além de `typing` para `agent_thinking`);
  4. updates ambíguos continuam com fallback inteligente via LLM.

### Processamento de Imagens/Logs como Arquivo (SPR-070 / Telegram + Executor)
- Objetivo:
  - fechar o gap de ingestão de anexos no canal Telegram para imagens e logs;
  - manter segredo do token Telegram fora do histórico persistido de sessão;
  - permitir fallback textual para logs mesmo quando o provider ativo não suporta multimodal nativo.
- Interfaces públicas:
  - `Pincer.Channels.Telegram.UpdatesProvider.prepare_input_content/2`
  - `Pincer.Core.Executor.resolve_attachment_url/2`
- Regras v1:
  - updates Telegram com `photo` e `document` devem ser transformados em payload multimodal (`attachment_ref`) para `Session.Server.process_input/2`;
  - anexos devem usar URL interna sem token (`telegram://file/<file_path>`) no histórico de sessão;
  - `Executor` deve resolver `telegram://file/...` para URL real somente em runtime, usando token atual;
  - quando `attachment_ref` tiver `mime_type` textual (`text/*`) e provider ativo não suportar arquivos:
    - baixar conteúdo do arquivo e converter para parte textual (`type=text`) em vez de descartar;
    - manter fallback existente para tipos não textuais.
- Critérios de aceite:
  1. `prepare_input_content/2` converte foto em `attachment_ref` com metadata estável;
  2. `prepare_input_content/2` converte `.log` em `attachment_ref` com `mime_type=text/plain`;
  3. `resolve_attachment_url/2` converte corretamente `telegram://file/...` e falha sem token;
  4. cobertura de testes para parser de anexos Telegram e resolução de URL de attachment.

### Sidecar v2: Checksum de Artefato + Auditoria Enriquecida (SPR-071)
- Objetivo:
  - fechar o item restante de hardening do sidecar v2 com validação explícita de checksum de artefato;
  - enriquecer telemetria de execução com metadados de skill (`id`, `version`, `artifact_checksum`);
  - manter postura fail-closed no `skills_sidecar`.
- Interfaces públicas:
  - `Pincer.Connectors.MCP.SkillsSidecarPolicy.validate/1`
  - `Pincer.Connectors.MCP.Manager.audit_sidecar_result/6`
- Regras v1:
  - `skills_sidecar` deve declarar `artifact_checksum` (ou alias `skill_artifact_checksum`) em formato:
    - `sha256:<64-hex>`;
  - ausência de checksum deve falhar com `:artifact_checksum_required`;
  - checksum malformado deve falhar com `:invalid_artifact_checksum`;
  - `audit_sidecar_result/6` deve:
    - ler `skill_id`, `skill_version` e `artifact_checksum` dos argumentos da tool call quando presentes;
    - fallback para valores `unknown`/`skills_sidecar` quando ausentes.
- Critérios de aceite:
  1. policy rejeita sidecar sem `artifact_checksum`;
  2. policy aceita sidecar hardened com checksum válido;
  3. `resolve_servers_config/2` mantém sidecar hardened apenas quando checksum está válido;
  4. auditoria por execução inclui metadata de `skill_version` e `artifact_checksum` quando fornecidos.

### Containerização do Servidor (SPR-072 / Docker Runtime v1)
- Objetivo:
  - empacotar o servidor Pincer em imagem Docker reproduzível para execução local/host;
  - manter persistência de dados/logs por volume sem gravar estado efêmero na camada da imagem;
  - expor comando único para subir o servidor (`mix pincer.server`) em ambiente containerizado.
- Interfaces públicas:
  - `Dockerfile` (build da imagem de runtime)
  - `.dockerignore` (redução de contexto de build)
  - `docker-compose.yml` (orquestração local do serviço `pincer-server`)
- Regras v1:
  - build multi-stage (`builder` + `runtime`) com Elixir/Erlang compatíveis;
  - imagem final deve executar como usuário não-root;
  - runtime deve montar `db/`, `logs/` e `sessions/` como volumes bind locais;
  - inicialização padrão do container deve executar:
    - `mix pincer.server`;
  - configuração sensível deve entrar por `.env`/`env_file`, sem hardcode de segredos em imagem.
- Critérios de aceite:
  1. `docker compose build pincer-server` conclui com sucesso;
  2. `docker compose up -d pincer-server` sobe container em execução;
  3. logs do container exibem bootstrap do servidor Pincer sem crash imediato;
  4. `docker compose down` encerra o serviço sem perda dos dados persistidos em `db/` e `logs/`.
