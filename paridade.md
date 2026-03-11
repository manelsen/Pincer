# Paridade de Ferramentas do Pincer

Data de reavaliacao: 2026-03-10

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

Ferramentas nativas expostas hoje:

- `file_system`: listar e ler arquivos
- `change_model`: trocar modelo
- `schedule_reminder`, `schedule_cron_job`, `list_cron_jobs`, `delete_cron_job`
- `schedule_timer_delay`
- `get_my_github_repos`
- `dispatch_agent`
- `read_blackboard`
- `safe_shell`
- `web` (`search`, `fetch`)
- `graph_history`
- `get_code_skeleton`
- `record_learning`
- `ingest_external_knowledge`, `search_external_knowledge`

Leitura objetiva:

- o Pincer tem um `tool belt central bom`
- e forte em `shell + web + cron + memoria + subagentes`
- mas ainda e `estreito` perto de Hermes e OpenClaw

## Benchmark Surface

Referencias principais dos benchmarks:

- Hermes: [tools/__init__.py](/home/micelio/git/hermes-agent/tools/__init__.py)
- OpenClaw: [src/agents/tools](/home/micelio/git/openclaw/src/agents/tools), [src/browser](/home/micelio/git/openclaw/src/browser), [src/plugin-sdk](/home/micelio/git/openclaw/src/plugin-sdk)
- Spacebot: [src/tools](/home/micelio/git/spacebot/src/tools), [src/api/server.rs](/home/micelio/git/spacebot/src/api/server.rs)
- Nullclaw: [src/tools](/home/micelio/git/nullclaw/src/tools), [src/memory](/home/micelio/git/nullclaw/src/memory)

## Matriz por Categoria

| Categoria | Pincer | Hermes | OpenClaw | Spacebot | Nullclaw |
| --- | --- | --- | --- | --- | --- |
| Arquivos | Parcial | Forte | Forte | Forte | Forte |
| Shell / execucao | Forte | Forte | Medio | Forte | Forte |
| Web search / fetch | Forte | Forte | Forte | Medio | Forte |
| Browser automation | Nao tem | Forte | Muito forte | Forte | Forte |
| Memoria explicita | Forte | Forte | Forte | Forte | Muito forte |
| Recall / diagnostico de memoria | Forte | Medio-forte | Forte | Muito forte | Muito forte |
| Cron / timers | Forte | Forte | Forte | Forte | Forte |
| Delegacao / subagentes | Forte | Forte | Forte | Forte | Forte |
| Skills | Parcial | Forte | Medio | Forte | Fraco-medio |
| MCP | Forte | Medio | Medio | Forte | Forte |
| Git / repo ops | Fraco | Medio | Medio | Medio | Forte |
| GitHub / APIs externas | Fraco-medio | Medio | Forte | Medio | Medio |
| Messaging ativa | Fraco | Forte | Muito forte | Forte | Medio |
| Visao / imagem / OCR / TTS | Nao tem | Muito forte | Forte | Fraco-medio | Medio |
| Secrets / config ops | Fraco | Medio | Forte | Forte | Medio |
| Task / project / workflow ops | Fraco | Medio | Forte | Forte | Medio |
| Hardware / device / system ops | Nao tem | Fraco-medio | Forte | Fraco | Forte |

## Score de Paridade por Ferramentas

Leitura ponderada por utilidade pratica:

- `Pincer vs Hermes`: `78/100`
- `Pincer vs OpenClaw`: `62/100`
- `Pincer vs Spacebot`: `58/100`
- `Pincer vs Nullclaw`: `55/100`

Interpretacao:

- `Hermes` e o benchmark mais proximo se o assunto for tool surface util ao agente
- `OpenClaw` ainda abre distancia por browser, messaging ativa, gateway actions e plugin/tool breadth
- `Spacebot` ganha menos por “ferramenta do agente” pura e mais por plataforma, mas ainda tem varias tools operacionais que o Pincer nao tem
- `Nullclaw` e muito largo em systems/memory/web/device, embora a experiencia de tool belt seja diferente

## Onde o Pincer Ja Esta Bem

- `shell`: [lib/pincer/tools/safe_shell.ex](/home/micelio/git/Pincer/lib/pincer/tools/safe_shell.ex)
- `web search/fetch`: [lib/pincer/tools/web.ex](/home/micelio/git/Pincer/lib/pincer/tools/web.ex)
- `cron/timer`: [lib/pincer/tools/scheduler.ex](/home/micelio/git/Pincer/lib/pincer/tools/scheduler.ex), [lib/pincer/tools/timer.ex](/home/micelio/git/Pincer/lib/pincer/tools/timer.ex)
- `delegacao`: [lib/pincer/tools/orchestrator.ex](/home/micelio/git/Pincer/lib/pincer/tools/orchestrator.ex)
- `memoria`: [lib/pincer/core/memory_recall.ex](/home/micelio/git/Pincer/lib/pincer/core/memory_recall.ex), [lib/pincer/core/memory_diagnostics.ex](/home/micelio/git/Pincer/lib/pincer/core/memory_diagnostics.ex), [lib/pincer/storage/adapters/postgres.ex](/home/micelio/git/Pincer/lib/pincer/storage/adapters/postgres.ex)
- `MCP`: [lib/pincer/adapters/connectors/mcp/manager.ex](/home/micelio/git/Pincer/lib/pincer/adapters/connectors/mcp/manager.ex)

Resumo:

- o Pincer ja e forte no miolo de agente autonomo
- o gap principal nao esta mais em memoria basica
- o gap principal esta em `largura e profundidade do cinturão de ferramentas`

## Gaps Mais Relevantes

### 1. Browser

Benchmarks que puxam esse eixo:

- Hermes: [tools/browser_tool.py](/home/micelio/git/hermes-agent/tools/browser_tool.py)
- OpenClaw: [src/agents/tools/browser-tool.ts](/home/micelio/git/openclaw/src/agents/tools/browser-tool.ts), [src/browser](/home/micelio/git/openclaw/src/browser)
- Spacebot: [src/tools/browser.rs](/home/micelio/git/spacebot/src/tools/browser.rs)
- Nullclaw: [src/tools/browser.zig](/home/micelio/git/nullclaw/src/tools/browser.zig)

Estado do Pincer:

- nao ha browser automation nativa

Impacto de paridade:

- este e o maior gap unitario contra Hermes e OpenClaw

### 2. Tooling de arquivos e edicao

Benchmarks:

- Hermes: `file_tools`, `file_operations`, `patch`
- Nullclaw: `file_read`, `file_write`, `file_edit`, `file_append`
- Spacebot: [src/tools/file.rs](/home/micelio/git/spacebot/src/tools/file.rs)

Estado do Pincer:

- [lib/pincer/tools/file_system.ex](/home/micelio/git/Pincer/lib/pincer/tools/file_system.ex) so cobre `list` e `read`

Gap:

- falta `write`
- falta `patch/apply diff`
- falta `search/grep`
- falta manipulacao mais ergonomica para codigo

### 3. Messaging ativa e acoes por canal

Benchmarks:

- Hermes: [tools/send_message_tool.py](/home/micelio/git/hermes-agent/tools/send_message_tool.py)
- OpenClaw: `discord-actions`, `telegram-actions`, `slack-actions`, `whatsapp-actions`, `message-tool`
- Spacebot: `reply`, `send_file`, `send_message_to_another_channel`

Estado do Pincer:

- o runtime de canais existe, mas a tool surface para o agente agir ativamente nesses canais ainda e fina

Gap:

- falta mandar mensagem arbitraria entre canais/alvos
- falta enviar arquivo
- falta acoes mais ricas por plataforma

### 4. Visao, audio e multimidia

Benchmarks:

- Hermes: `vision_tools`, `image_generation_tool`, `tts_tool`, `transcription_tools`
- OpenClaw: `image-tool`, `pdf-tool`, `tts-tool`

Estado do Pincer:

- praticamente ausente como tool nativa

Gap:

- OCR/vision
- TTS
- transcricao
- PDF e imagem como ferramentas de primeira classe

### 5. Git / repo ops

Benchmarks:

- Nullclaw: [src/tools/git.zig](/home/micelio/git/nullclaw/src/tools/git.zig)
- Hermes cobre isso mais indiretamente via terminal e file tools

Estado do Pincer:

- [lib/pincer/tools/github.ex](/home/micelio/git/Pincer/lib/pincer/tools/github.ex) cobre apenas listagem de repos do proprio usuario

Gap:

- status, diff, branches, commits, logs, blame, search em repo

### 6. Workflow ops

Benchmarks:

- Spacebot: tasks, projects, workers, memories, secrets, inspect via API
- OpenClaw: gateway, sessions, nodes, agents
- Hermes: todo, clarify, delegate

Estado do Pincer:

- ha runtime de projeto e orquestracao, mas pouca tool surface explicitamente exposta para o agente operar esse mundo

Gap:

- tasks/todo
- projeto/worktree/repo ops
- inspecao de sessao e de runtime via tools

## O Que Eu Faria Primeiro

Ordem por `ROI de paridade`:

1. `file editing suite`
2. `browser automation`
3. `send_message/send_file/channel actions`
4. `vision + pdf + transcription`
5. `git ops`
6. `workflow ops` (`todo`, `task`, `project inspect/manage`)

## Melhor Alvo por Benchmark

### Para encostar no Hermes

Priorizar:

- browser
- file editing/patch/search
- todo/task tool
- vision/transcription/TTS

### Para encostar no OpenClaw

Priorizar:

- browser forte
- channel actions
- PDF/image tooling
- sessao/message tools

### Para encostar no Spacebot

Priorizar:

- project/task/worker tools
- channel routing/message tools
- memoria operacional integrada com graph inspection

### Para encostar no Nullclaw

Priorizar:

- file suite forte
- git/system/device tools
- web search breadth
- memoria ainda mais profunda

## Conclusao

Se o que mais importa e `ferramentas`, o Pincer ainda tem bastante espaco para crescer.

O lado bom e que o gap agora e muito claro:

- menos “infra basica”
- menos “memoria v1”
- mais `tool belt`

Em uma frase:

> o Pincer ja tem um bom cerebro; agora precisa de mais maos.
