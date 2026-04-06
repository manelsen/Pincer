# SPECS — ClawHub Skills + Proatividade/Auto-Reflexao + Logging INFO

## Problema

O Pincer esta com log default em `DEBUG`, sem integracao explicita com ClawHub para descoberta/instalacao de skills, e sem um loop estruturado de auto-reflexao proativa inspirado no ArgentOS Core.

## Objetivos

1. Alterar o nivel padrao de log para `INFO`.
2. Adicionar suporte de registro de skills via ClawHub no fluxo `Pincer.Core.Skills`.
3. Adicionar mecanismo de auto-reflexao e proatividade baseado em traces recentes do `Executor`.

## Interfaces (Doc-First)

### 1) Logging

- Arquivo alvo: `config/config.exs`
- Mudanca:
  - `config :logger, level: :info`

### 2) ClawHub Skills Registry

- Novo modulo: `Pincer.Adapters.SkillsRegistry.ClawHub`
- API publica:
  - `list_skills(opts \\ []) :: {:ok, [map()]} | {:error, term()}`
  - `fetch_skill(skill_id, opts \\ []) :: {:ok, map()} | {:error, term()}`
- Entradas esperadas em `opts`:
  - `:base_url` (default: `https://api.clawhub.dev`)
  - `:api_key` (opcional; usa env `CLAWHUB_API_KEY` quando ausente)
  - `:http_client` (injecao para testes; default `Req`)
  - `:registry_path` (default endpoint de skills)

### 3) Core Skills com selecao de registry

- Modulo: `Pincer.Core.Skills`
- Nova regra:
  - `registry_config/1` deve aceitar `registry: :clawhub` e mapear para `Pincer.Adapters.SkillsRegistry.ClawHub`.
  - Mantem compatibilidade com `registry: module()`.

### 4) Auto-reflexao + proatividade

- Novo modulo: `Pincer.Core.Reflection`
- API publica:
  - `next_prompt(trace_metadata, opts \\ []) :: {:ok, String.t()} | :ignore`
  - `classify(trace_metadata) :: :success | :failure | :tool_heavy | :shallow`
- Integracao:
  - `Pincer.Core.Session.Server` passa a armazenar ultimo trace recebido em estado.
  - A cada `:heartbeat`, quando sessao estiver `:idle`, pode disparar um prompt interno de reflexao via `process_standard_input/2`, sem depender de mensagem do usuario.
- Regras iniciais:
  - Somente refletir quando houver trace recente.
  - Throttle minimo entre reflexoes (configuravel por opts).
  - Nunca refletir se worker estiver ativo.

## TDD (RED -> GREEN -> REFACTOR)

### Testes RED previstos

1. `test/pincer/adapters/skills_registry/clawhub_test.exs`
   - lista skills a partir de payload ClawHub
   - busca skill por id
   - trata erro HTTP/JSON invalido

2. `test/pincer/core/skills_test.exs` (incremental)
   - `registry: :clawhub` resolve para adapter correto

3. `test/pincer/core/reflection_test.exs`
   - classifica trace com erro como `:failure`
   - gera prompt quando trace e elegivel
   - retorna `:ignore` sem dados suficientes

4. `test/pincer/core/session_server_test.exs` (incremental)
   - heartbeat em estado idle usa reflexao (quando elegivel)
   - heartbeat nao dispara reflexao com worker ativo

## Restricoes e seguranca

- Manter boundary:
  - `Core` nao faz HTTP direto.
  - HTTP fica no adapter `Pincer.Adapters.SkillsRegistry.ClawHub`.
- Sem catches amplos silenciosos.
- Reaproveitar validacoes existentes de `Pincer.Core.Skills` para source/checksum/path.

