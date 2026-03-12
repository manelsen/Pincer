# Paridade de Ferramentas do Pincer

Data de reavaliacao: 2026-03-12

## TODO

- [ ] `file_system`: adicionar `write`, `search/grep`, `move`, `delete`
- [ ] `file_system`: implementar `read_hashline` (retorna arquivo com hash de 5 hex por linha)
- [ ] `file_system`: implementar `edit_hashline` (edita linhas por referencia de hash)
- [ ] `executor`: anotar tool results com hash curto antes de entrar no historico (ponteiros que sobrevivem a compressao)
- [ ] `graph_memory`: substituir exibicao de UUID por alias de 5 hex nas respostas ao LLM
- [ ] `blackboard`: adicionar hash de display curto em entradas para referencias cross-agent
- [ ] `tool result truncation`: anotar itens antes do corte; expor pagination por hash
- [ ] `browser`: wait_for_selector, multiplas abas, upload de arquivo
- [ ] `channel_actions`: Slack, reactions/threads Discord, agendamento de mensagem
- [ ] `media`: image generation (DALL-E / Imagen)
- [ ] `secrets/config`: leitura e escrita de env vars por workspace

## Escopo

Este documento compara **superficie de ferramentas** do Pincer contra:

- Hermes
- OpenClaw
- Spacebot
- Nullclaw

O foco aqui nao e UI, control plane ou arquitetura geral. O foco e:

- quais ferramentas o agente tem para trabalhar
- quao profundas elas sao
- quao longe o Pincer ainda esta dos benchmarks

Base principal do Pincer:

- [lib/pincer/adapters/native_tool_registry.ex](/home/micelio/git/Pincer/lib/pincer/adapters/native_tool_registry.ex)
- [lib/pincer/tools](/home/micelio/git/Pincer/lib/pincer/tools)
- [lib/pincer/adapters/tools](/home/micelio/git/Pincer/lib/pincer/adapters/tools)

## Inventario Atual do Pincer

Ferramentas nativas expostas hoje (18 modulos, ~80 acoes):

- `file_system`: listar e ler arquivos
- `change_model`, `config`: trocar modelo / config runtime
- `schedule_reminder`, `schedule_cron_job`, `list_cron_jobs`, `delete_cron_job`
- `schedule_timer_delay`
- `github`: list_repos, list_prs, list_issues, get_pr, get_issue, create_issue, comment, search_code, list_commits + legacy `get_my_github_repos`
- `git_inspect`: status, diff, log, blame, branches, show, stash — ops locais de repo
- `dispatch_agent`, orchestrator
- `read_blackboard`
- `safe_shell`
- `web` (`search`, `fetch`)
- `graph_history`, `record_learning`, `ingest_external_knowledge`, `search_external_knowledge`
- `get_code_skeleton`
- `channel_actions`: send_message, **send_file**, **reply_to**
- `browser`: navigate, click, fill, press, select, screenshot, **screenshot_inline** (multimodal), extract_text, get_attribute, evaluate, content, close_session
- `media`: **describe** (vision), **ocr**, **pdf_extract**, **tts**, **transcribe**
- `workflow`: list_sessions, get_session, list_agents, list_projects, get_board, list_tasks, create_task, get_task, update_task

Leitura objetiva:

- o Pincer agora tem um `tool belt substancialmente mais largo` que ha dois dias
- os gaps classicos de visao, browser, messaging e workflow foram endereçados
- o gap principal que permanece e `file editing + secrets/config ops + hardware`

## Benchmark Surface

Referencias principais dos benchmarks:

- Hermes: [tools/__init__.py](/home/micelio/git/hermes-agent/tools/__init__.py)
- OpenClaw: [src/agents/tools](/home/micelio/git/openclaw/src/agents/tools), [src/browser](/home/micelio/git/openclaw/src/browser), [src/plugin-sdk](/home/micelio/git/openclaw/src/plugin-sdk)
- Spacebot: [src/tools](/home/micelio/git/spacebot/src/tools), [src/api/server.rs](/home/micelio/git/spacebot/src/api/server.rs)
- Nullclaw: [src/tools](/home/micelio/git/nullclaw/src/tools), [src/memory](/home/micelio/git/nullclaw/src/memory)

## Matriz por Categoria

| Categoria | Pincer (antes) | Pincer (hoje) | Hermes | OpenClaw | Spacebot | Nullclaw |
| --- | --- | --- | --- | --- | --- | --- |
| Arquivos | Parcial | Parcial | Forte | Forte | Forte | Forte |
| Shell / execucao | Forte | Forte | Forte | Medio | Forte | Forte |
| Web search / fetch | Forte | Forte | Forte | Forte | Medio | Forte |
| Browser automation | Nao tem | **Medio** | Forte | Muito forte | Forte | Forte |
| Memoria explicita | Forte | Forte | Forte | Forte | Forte | Muito forte |
| Recall / diagnostico de memoria | Forte | Forte | Medio-forte | Forte | Muito forte | Muito forte |
| Cron / timers | Forte | Forte | Forte | Forte | Forte | Forte |
| Delegacao / subagentes | Forte | Forte | Forte | Forte | Forte | Forte |
| Skills | Parcial | Parcial | Forte | Medio | Forte | Fraco-medio |
| MCP | Forte | Forte | Medio | Medio | Forte | Forte |
| Git / repo ops | Fraco | **Medio-forte** | Medio | Medio | Medio | Forte |
| GitHub / APIs externas | Fraco-medio | **Medio-forte** | Medio | Forte | Medio | Medio |
| Messaging ativa | Fraco | **Medio-forte** | Forte | Muito forte | Forte | Medio |
| Visao / imagem / OCR / TTS | Nao tem | **Forte** | Muito forte | Forte | Fraco-medio | Medio |
| Secrets / config ops | Fraco | Fraco | Medio | Forte | Forte | Medio |
| Task / project / workflow ops | Fraco | **Medio-forte** | Medio | Forte | Forte | Medio |
| Hardware / device / system ops | Nao tem | Nao tem | Fraco-medio | Forte | Fraco | Forte |

## Score de Paridade por Ferramentas

Leitura ponderada por utilidade pratica:

| Benchmark | Antes | Hoje | Delta |
| --- | --- | --- | --- |
| Hermes | 78/100 | **86/100** | +8 |
| OpenClaw | 62/100 | **74/100** | +12 |
| Spacebot | 58/100 | **68/100** | +10 |
| Nullclaw | 55/100 | **63/100** | +8 |

Interpretacao:

- `OpenClaw` foi o benchmark que mais ganhou chao — browser + messaging + visao + workflow fecharam os gaps mais visados
- `Hermes` continua o mais proximo mas agora com margem menor; o restante do gap e imagem com geracao (nao so leitura) e skills
- `Spacebot` ainda leva por project/worker ops mais profundos e secrets/config
- `Nullclaw` abre distancia em file suite completa e device/system ops

## Onde o Pincer Ja Esta Bem

- `shell`: [lib/pincer/tools/safe_shell.ex](/home/micelio/git/Pincer/lib/pincer/tools/safe_shell.ex)
- `web search/fetch`: [lib/pincer/tools/web.ex](/home/micelio/git/Pincer/lib/pincer/tools/web.ex)
- `cron/timer`: [lib/pincer/tools/scheduler.ex](/home/micelio/git/Pincer/lib/pincer/tools/scheduler.ex), [lib/pincer/tools/timer.ex](/home/micelio/git/Pincer/lib/pincer/tools/timer.ex)
- `delegacao`: [lib/pincer/tools/orchestrator.ex](/home/micelio/git/Pincer/lib/pincer/tools/orchestrator.ex)
- `memoria`: graph memory + external knowledge + learning
- `MCP`: [lib/pincer/adapters/connectors/mcp/manager.ex](/home/micelio/git/Pincer/lib/pincer/adapters/connectors/mcp/manager.ex)
- `visao / multimidia`: [lib/pincer/tools/media.ex](/home/micelio/git/Pincer/lib/pincer/tools/media.ex) — describe, OCR, PDF, TTS, transcricao
- `browser`: [lib/pincer/tools/browser.ex](/home/micelio/git/Pincer/lib/pincer/tools/browser.ex) + [priv/browser/server.js](/home/micelio/git/Pincer/priv/browser/server.js) — Playwright Node sidecar, 12 acoes + screenshot multimodal inline
- `git/github`: [lib/pincer/tools/git_inspect.ex](/home/micelio/git/Pincer/lib/pincer/tools/git_inspect.ex) + [lib/pincer/tools/github.ex](/home/micelio/git/Pincer/lib/pincer/tools/github.ex) — ops locais + 9 acoes de API
- `channel messaging`: [lib/pincer/tools/channel_actions.ex](/home/micelio/git/Pincer/lib/pincer/tools/channel_actions.ex) — send_message + send_file + reply_to
- `workflow/tasks`: [lib/pincer/tools/workflow.ex](/home/micelio/git/Pincer/lib/pincer/tools/workflow.ex) — session inspect + tasks CRUD + project board

## Gaps Que Permanecem

### 1. File editing suite (MAIOR GAP RESTANTE)

Estado:

- [lib/pincer/tools/file_system.ex](/home/micelio/git/Pincer/lib/pincer/tools/file_system.ex) ainda cobre apenas `list` e `read`

Gap:

- falta `write` (criar/sobrescrever arquivo)
- falta `patch/apply diff` (editar trecho especifico)
- falta `search/grep` (buscar conteudo em arquivos)
- falta `move`, `copy`, `delete`

Impacto: sem isso o agente nao pode modificar codigo autonomamente sem recorrer ao `safe_shell`

### 2. Browser: profundidade ainda abaixo dos benchmarks

Estado:

- Playwright sidecar funcional com 12 acoes
- screenshot multimodal inline implementado

Gap vs OpenClaw/Hermes:

- falta `wait_for_selector` / `wait_for_navigation` explicito
- falta gerenciamento de cookies/sessao persistente
- falta suporte a multiplas abas / frames
- falta intercept de requests (proxy/mock)
- falta upload de arquivo via browser

### 3. Secrets / config ops

Estado: praticamente ausente como tool nativa

Gap:

- leitura/escrita de env vars de workspace
- gestao de secrets por agente
- validacao de config runtime

### 4. Messaging ativa: profundidade por plataforma

Estado:

- send_message + send_file + reply_to agora cobertos
- apenas 3 canais (telegram, discord, whatsapp)

Gap vs OpenClaw:

- falta acoes especificas por plataforma (reactions, pins, threads, embeds Discord)
- falta Slack
- falta agendamento de mensagem

### 5. Visao: geracao de imagem ausente

Estado:

- leitura forte (describe, ocr, pdf_extract, transcribe, tts)

Gap vs Hermes:

- falta `image_generation` (DALL-E / Imagen)
- falta edicao de imagem

### 6. Hardware / device / system ops

Estado: nao implementado

Gap vs Nullclaw/OpenClaw:

- system info (CPU, memoria, disco)
- process management
- clipboard, notifications

## Score de Paridade Restante por Gap

Priorizacao por ROI de paridade:

1. `file editing suite` — desbloqueia autonomia de codigo; impacto alto em todos os benchmarks
2. `browser depth` — wait, tabs, upload; fecha gap vs OpenClaw
3. `secrets/config ops` — fecha gap vs Spacebot
4. `messaging breadth` — Slack, reactions, threads
5. `image generation` — fecha gap vs Hermes no eixo visao
6. `hardware/system` — fecha gap vs Nullclaw

## Conclusao

O Pincer passou de `estreito` para `competitivo` no eixo de tool surface.

O gap agora nao e mais de categorias ausentes — e de profundidade dentro de categorias ja abertas.

Em uma frase:

> o Pincer ja tem maos; agora precisa de maos mais habeis.
