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

## Incremento 2026-03-02 (Normalizacao de Exports em Boundaries)

### Objetivo
- Corrigir regressao de declaracao de `exports` em boundaries que causou warnings massivos de:
  - `unknown module ... is listed as an export`
  - `forbidden reference ... is not exported by its owner boundary`

### Escopo
- Ajustar somente:
  - `lib/pincer/core.ex`
  - `lib/pincer/infra.ex`
  - `lib/pincer/ports.ex`

### Regras
- Dentro de um `defmodule` que usa `Boundary`, a lista `exports` deve usar aliases relativos ao boundary dono.
- Exemplo em `defmodule Pincer.Core`:
  - correto: `Session.Server`
  - incorreto: `Pincer.Core.Session.Server`

### Criterios de aceite
1. Os exports dos tres boundaries acima usam aliases relativos.
2. Teste de regressao cobre o padrao e falha quando alias absoluto do proprio boundary reaparece.
3. `mix compile` nao emite mais warnings de `unknown module Pincer.<Boundary>.Pincer...` para esses arquivos.

---

## Incremento 2026-03-02 (Warnings de Boundary no Startup)

### Objetivo
- Eliminar warnings recorrentes de compilacao/startup:
  - `Mix.Tasks.Pincer.* is not included in any boundary`
  - `HtmlEntities is not included in any boundary`

### Escopo
- Classificacao manual de mix tasks para boundary dedicado de tooling.
- Namespacing do decoder HTML usado no tool web para dentro de boundary existente.

### Interface/Contrato
- Boundary de tooling:
  - `Pincer.Mix` com `top_level?: true` e `check: [in: false, out: false]`.
- Mix tasks:
  - `Mix.Tasks.Pincer.Chat|Doctor|Onboard|SecurityAudit|Server` usam
    `use Boundary, classify_to: Pincer.Mix`.
- Decoder HTML:
  - substituir `HtmlEntities` top-level por `Pincer.Adapters.Tools.Web.HtmlEntities`.

### Criterios de aceite
1. `mix compile` nao emite mais os dois warnings acima.
2. `mix pincer.server service restart` nao registra esses warnings no `journalctl`.
3. Teste de regressao cobre classificacao das tasks e namespacing do decoder.

---

## Incremento 2026-03-02 (Resiliencia do Cron Scheduler + Repo Config)

### Objetivo
- Impedir crash-loop do `Pincer.Adapters.Cron.Scheduler` quando o schema de cron ainda nao foi migrado.
- Corrigir configuracao de `ecto_repos` para usar o repo real do projeto (`Pincer.Infra.Repo`).

### Escopo
- `lib/pincer/adapters/cron/scheduler.ex`
- `config/config.exs`
- testes de regressao em `test/pincer/adapters/cron/scheduler_test.exs` e `test/pincer/config/db_defaults_test.exs`

### Regras
- No tick do scheduler, erro de banco `no such table: cron_jobs` nao pode derrubar o processo.
- Scheduler deve permanecer vivo e registrar warning acionavel (uma vez por ciclo de vida do processo) enquanto o schema estiver ausente.
- Fluxo normal de dispatch/reschedule de jobs deve permanecer inalterado.
- `:ecto_repos` deve apontar para `Pincer.Infra.Repo`.

### Criterios de aceite
1. Teste prova que `:tick` com erro `no such table: cron_jobs` nao encerra o scheduler.
2. Teste prova que fluxo normal ainda despacha e reschedule jobs.
3. Teste de config valida `Application.get_env(:pincer, :ecto_repos) == [Pincer.Infra.Repo]`.
4. `mix compile` e `mix test` dos arquivos alterados passam.

---

## Incremento 2026-03-07 (Telegram Replay + Bootstrap Recovery + Stream Hygiene)

### Objetivo
- Impedir respostas duplicadas no Telegram causadas por replay de updates apos restart.
- Impedir reentrada indevida em bootstrap quando `IDENTITY.md` e `SOUL.md` ja existem.
- Preservar respostas do assistente no storage para manter contexto apos reinicio de sessao.
- Impedir que o stream sintetico OpenAI-compatible vaze texto de planejamento junto com `tool_calls`.

### Interfaces/Public API
- `Pincer.Channels.Telegram.UpdatesProvider.start_link/1`
  - aceita opcionalmente `offset_path:` para carregar/persistir o ultimo `update_id + 1`.
- `Pincer.Channels.Telegram.UpdatesProvider.load_offset/1`
- `Pincer.Channels.Telegram.UpdatesProvider.persist_offset/2`
- `Pincer.Core.Session.Server.bootstrap_active?/2`
  - decide se `BOOTSTRAP.md` ainda deve influenciar o prompt/sessao.

### Regras
- O poller do Telegram deve iniciar a partir do offset persistido quando disponivel.
- Apos polling bem-sucedido com updates, o novo offset deve ser persistido antes do proximo ciclo.
- `BOOTSTRAP.md` so entra no prompt e so dispara `:trigger_bootstrap` quando a identidade ainda nao foi estabelecida.
- Respostas finais do assistente devem ser persistidas com role `assistant`.
- `OpenAICompat.message_to_stream_chunks/1` nao deve incluir `"content"` no mesmo delta sintetico que carrega `tool_calls`.

### Criterios de aceite
1. Teste prova que o `UpdatesProvider` relanca usando o offset persistido e atualiza esse valor apos sucesso.
2. Teste prova que `bootstrap_active?/2` desativa bootstrap quando `IDENTITY.md` e `SOUL.md` existem.
3. Teste prova que respostas do assistente sao persistidas no storage.
4. Teste prova que `message_to_stream_chunks/1` nao vaza `content` quando `tool_calls` estao presentes.

---

## Incremento 2026-03-07 (Telegram streaming sem duplicacao nem vazamento bruto)

### Objetivo
- Impedir que respostas longas do Telegram aparecam duplicadas quando o fluxo usa preview (`agent_partial`) seguido de finalizacao (`agent_response`).
- Impedir que o preview exponha reasoning bruto em cenarios de "stream" sintetico em que o backend entrega a resposta inteira em um unico token.

### Escopo
- `lib/pincer/channels/telegram.ex`
- `lib/pincer/channels/telegram/session.ex`
- `test/pincer/channels/telegram_session_test.exs`
- `test/pincer/channels/telegram_test.exs`

### Interface/Contrato
- `Pincer.Channels.Telegram.send_message/3`
- `Pincer.Channels.Telegram.update_message/4`
- Fluxo de finalizacao em `Pincer.Channels.Telegram.Session`

### Regras
- Se existir preview ativo e a resposta final exceder o limite seguro do Telegram, o primeiro chunk deve reutilizar a mensagem ja existente; nao pode reenviar o texto inteiro do zero.
- O preview de streaming deve ser suprimido quando o primeiro token ja representa uma resposta inteira/grande demais para streaming util.
- Quando `reasoning_visible` estiver ativo, a formatacao de reasoning continua suportada no envio final, mas o preview nao deve despejar o bloco bruto completo de uma resposta sintetica.

### Criterios de aceite
1. Caminho `partial + final` curto continua finalizando in-place sem envio extra.
2. Caminho `partial + final` longo resulta em uma unica resposta final visivel, sem duplicar o primeiro chunk.
3. Teste de regressao cobre supressao de preview para token unico/grande.
4. Testes Telegram relevantes passam.

---

## Incremento 2026-03-09 (Memoria Operacional P0/P1)

### Objetivo
- Fechar o gap principal de memoria do Pincer: `recall operacional` durante o loop do agente.
- Adicionar busca textual no storage transacional para historico e snippets.
- Separar memoria narrativa do agente de memoria aprendida do usuario.
- Sanitizar memoria antes de injeta-la no prompt para reduzir risco de prompt injection.
- Fechar o loop do `Archivist`, persistindo snippets semanticamente recuperaveis.

### Interfaces/Public API
- `Pincer.Ports.Storage.search_messages/2`
- `Pincer.Ports.Storage.search_documents/2`
- `Pincer.Core.MemoryRecall.build/2`
- `Pincer.Core.MemoryRecall.eligible_query?/1`
- `Pincer.Core.MemoryRecall.sanitize_for_prompt/1`
- `Pincer.Core.Orchestration.Archivist.consolidate/3`
  - passa a atualizar `USER.md` com memoria aprendida do usuario
  - passa a indexar snippets extraidos no storage semantico/textual

### Regras
- O `Executor` deve realizar uma etapa de recall antes de chamar o LLM quando houver uma query elegivel.
- O recall v1 deve combinar:
  - `MEMORY.md` sanitizado
  - `USER.md` sanitizado
  - hits textuais de historico de mensagens
  - hits textuais de snippets/documentos
  - hits semanticos de documentos quando embeddings estiverem disponiveis
- O bloco de recall deve ser compacto, citar a origem de cada hit e rotular a memoria como dado nao-confiavel.
- Conteudo de memoria nao pode ser injetado cru no prompt quando contiver instrucoes como:
  - `ignore previous instructions`
  - `system:`
  - blocos `<thinking>` / `tool_calls` / fences markdown
- O storage transacional da epoca deve manter indice textual para:
  - `messages`
  - documentos/snippets em `nodes` do tipo `document`
- O `Archivist` deve:
  - atualizar `MEMORY.md` como hoje
  - atualizar uma secao gerenciada de memoria do usuario em `USER.md`
  - indexar snippets extraidos para busca textual e semantica
  - manter ingestao de bug/fix

### Criterios de aceite
1. Teste de unidade prova que `MemoryRecall` classifica queries, sanitiza memoria e formata citacoes.
2. Teste de integracao prova que o `Executor` injeta recall automatico no prompt antes da chamada ao LLM.
3. Teste de integracao prova busca textual em `messages` e em `document` snippets via adapter de storage.
4. Teste de regressao prova que memoria com padroes de prompt injection e neutralizada antes da injecao.
5. Teste de integracao prova que o `Archivist` atualiza `USER.md`, indexa snippets e preserva ingestao de bug/fix.
6. Testes existentes de sessao/memoria continuam verdes.

---

## Incremento 2026-03-14 (Diagnostico de Empty First Response em OpenAI-Compat)

### Objetivo
- Eliminar uma causa concreta de `Text length: 0` no primeiro passe de providers OpenAI-compatible usados via stream sintetico.
- Preservar campos de reasoning single-shot que alguns providers devolvem como `reasoning_content` em vez de `reasoning`.

### Escopo
- `lib/pincer/llm/providers/openai_compat.ex`
- `test/pincer/llm/providers/openai_compat_test.exs`

### Regras
- `handle_response/1` deve tratar `message["reasoning_content"]` como reasoning valido, da mesma forma que `message["reasoning"]` e `message["thought"]`.
- Quando houver `reasoning_content` e `content` vazio, o adapter deve preencher `content` com bloco `<thinking>...</thinking>` para que o stream sintetico nao vire delta vazio por perda de campo.
- A mudanca deve ser coberta por teste unitario focado no adapter, sem depender de chamada real ao provider.

### Criterios de aceite
1. Teste prova que resposta `200` com `message.reasoning_content` e sem `message.content` vira `{:ok, message, usage}` com `content` preenchido por bloco `<thinking>`.
2. `message_to_stream_chunks/1` continua gerando chunk nao-vazio para esse caso.
3. Testes relevantes do adapter passam.

---

## Incremento 2026-03-09 (Memoria P2: tipos, ranking, forget e busca cruzada)

### Objetivo
- Formalizar tipos de memoria semantica no storage.
- Permitir `forget/archive` seletivo por item de memoria.
- Expor busca cruzada entre sessoes como API dedicada.
- Melhorar ranking de memoria com metadados de importancia, acesso e recencia.
- Enriquecer citacoes com `source` e `line-range` quando houver metadata suficiente.

### Interfaces/Public API
- `Pincer.Ports.Storage.index_memory/5`
- `Pincer.Ports.Storage.search_documents/3`
- `Pincer.Ports.Storage.search_sessions/2`
- `Pincer.Ports.Storage.forget_memory/1`
- `Pincer.Core.MemoryTypes.normalize/1`
- `Pincer.Core.MemoryTypes.valid?/1`

### Regras
- Toda memoria semantica persistida em `nodes` do tipo `document` deve carregar `memory_type`.
- Tipos v1 suportados:
  - `reference`
  - `technical_fact`
  - `bug_solution`
  - `user_preference`
  - `architecture_decision`
  - `session_summary`
- `index_document/3` deve permanecer por compatibilidade, delegando para `index_memory/5`.
- `search_documents/3` deve aceitar filtros por:
  - `memory_type`
  - `session_id`
  - `include_forgotten`
- O ranking de documentos deve considerar:
  - score textual/semantico bruto
  - `importance`

---

## Incremento 2026-03-13 (Recuperacao de Context Overflow no Executor)

### Objetivo
- Transformar `context_overflow` em recuperacao concreta no `Executor`, em vez de apenas falha terminal.
- Centralizar a decisao de reducao de payload em politica pura de `Core`.

### Interfaces/Public API
- `Pincer.Core.ContextOverflowRecovery.plan/2`
- `Pincer.Core.Executor`
  - `prepare_prompt_history/3` aceita override de escala do limite seguro de contexto

### Regras
- Quando `ErrorClass.classify(reason) == :context_overflow`, o `Executor` deve:
  - reconstruir o prompt a partir do historico logico
  - reduzir agressivamente o limite seguro de contexto
  - remover `tools` da tentativa de fallback
- A politica pura nao executa efeitos nem acessa transporte/provider.
- O fallback deve preservar mensagens recentes e manter o `system` prompt.

### Criterios de aceite
1. Teste prova que `ContextOverflowRecovery.plan/2` gera retry plan so para `context_overflow`.
2. Teste prova que o `Executor` refaz o fallback com prompt menor e sem `tools`.
3. `mix test` dos arquivos novos/alterados passa.

---

## Incremento 2026-03-13 (Resposta Final Vazia nao e Sucesso)

### Objetivo
- Impedir que o `Executor` finalize com sucesso quando o provider encerra sem texto final e sem `tool_calls`.
- Evitar silencio no canal e historico poluido por respostas nulas.

### Interfaces/Public API
- `Pincer.Core.Executor`

### Regras
- Se a mensagem final do assistente chegar sem conteudo util e sem `tool_calls`, o `Executor` deve retornar `{:error, :empty_response}`.
- O resumo sintetico por tool usage continua permitido apenas quando houve uso real de ferramentas e existe material para resumir.
- Nao deve existir `{:executor_finished, ..., nil, ...}` para esse caso.

### Criterios de aceite
1. Teste prova que stream encerrado sem texto final vira `{:executor_failed, :empty_response}`.
2. Nao ha `executor_finished` nesse caso.
3. `mix test` dos arquivos alterados passa.

---

## Incremento 2026-03-13 (Turn Outcome Policy)

### Objetivo
- Centralizar a decisao de texto final visivel do turno em politica pura.
- Separar `final_text`, `tool-only summary` e `empty_response` do fluxo imperativo do `Executor`.

### Interfaces/Public API
- `Pincer.Core.TurnOutcomePolicy.resolve/1`

### Regras
- Se existir texto final explicito, ele vence.
- Se o final vier vazio mas houver texto visivel ja observado no stream, esse texto deve ser reutilizado.
- Se nao houver texto visivel, mas houver resultados de tools no turno, a politica pode devolver um resumo `tool-only`.
- Se nao houver nada user-visible, o resultado deve ser `{:error, :empty_response}`.

### Criterios de aceite
1. Teste prova a resolucao pura dos quatro casos: final, streamed fallback, tool-only e vazio.
2. `Executor` passa a usar essa politica em vez de sintetizar inline.
3. Testes relevantes do executor continuam verdes.

---

## Incremento 2026-03-13 (Browser Pool Ausente nao Pode Derrubar o Turno)

### Objetivo
- Impedir que o tool `browser` propague `exit` quando o pool/processo nao estiver iniciado.
- Garantir que falha de infraestrutura do browser vire erro normal de tool.

### Interfaces/Public API
- `Pincer.Adapters.Tools.Browser.execute/2`

### Regras
- Se o pool do browser estiver ausente ou morrer, `Browser.execute/2` deve retornar `{:error, ...}`.
- Nao pode escapar `exit(:noproc)` para o `Executor`.
- A mensagem de erro deve ser acionavel o suficiente para diagnostico operacional.

### Criterios de aceite
1. Teste prova que pool ausente nao derruba o teste/processo chamador.
2. `Browser.execute/2` retorna erro descritivo.
3. `mix test test/pincer/tools/browser_test.exs` passa.

---

## Incremento 2026-03-13 (Tool-Only Outcome nao Pode Fingir Sucesso)

### Objetivo
- Separar classificacao de outcome de turno da formatacao textual de `tool-only`.
- Impedir que um turno sem resposta final do assistente seja apresentado como "✅ Concluido".

### Interfaces/Public API
- `Pincer.Core.TurnOutcomePolicy.resolve/1`
- `Pincer.Core.ToolOnlyOutcomeFormatter.format/1`

### Regras
- `TurnOutcomePolicy` deve classificar `tool-only` sem construir o texto final inline.
- A formatacao de `tool-only` deve deixar claro que houve resposta parcial/incompleta, nao sucesso conclusivo.
- Se houver erros de ferramentas no material resumido, a mensagem deve assumir limitacao/falha parcial explicitamente.
- O resumo ainda pode reaproveitar previews curtos dos resultados de tools para diagnostico rapido.

### Criterios de aceite
1. Teste prova que `TurnOutcomePolicy` retorna um outcome estruturado para `tool-only`, sem string pronta.
2. Teste prova que `ToolOnlyOutcomeFormatter` nao usa "✅ Concluido" e menciona resposta parcial/incompleta.
3. Teste de executor/regressao cobre o caso pos-tool sem resposta final detalhada.

---

## Incremento 2026-03-13 (Split Web em `web_search` e `web_fetch`)

### Objetivo
- Separar a interface do tool web leve em duas capacidades explicitas.
- Reduzir a chance do modelo escolher `browser` para tarefas que pedem apenas busca ou fetch textual.

### Interfaces/Public API
- `Pincer.Adapters.Tools.Web.spec/0`
- `Pincer.Adapters.Tools.Web.execute/1`

### Regras
- O registry deve expor dois tools distintos: `web_search` e `web_fetch`.
- `web_search` aceita `query` e `count`, sem `action`.
- `web_fetch` aceita `url`, sem `action`.
- A logica de SSRF/redirect/extração textual continua valendo para `web_fetch`.
- Compatibilidade temporaria com a interface antiga `web` pode existir internamente, mas o nome legado nao deve mais ser exposto no registry nativo.

### Criterios de aceite
1. Teste prova que `NativeToolRegistry.list_tools/0` expõe `web_search` e `web_fetch`, e nao `web`.
2. Teste prova que o executor aceita deltas com `tool_call.name == "web_search"`.
3. Teste prova que `Web.execute/1` despacha corretamente por `tool_name` para `web_search` e `web_fetch`.

---

## Incremento 2026-03-13 (Nao Expor Browser Quando Indisponivel)

### Objetivo
- Impedir que o modelo escolha `browser` quando a infraestrutura do browser nao esta habilitada.
- Empurrar leitura simples de URL para `web_fetch`, nao para navegacao interativa.

### Interfaces/Public API
- `Pincer.Adapters.Tools.Browser.spec/0`
- `Pincer.Adapters.NativeToolRegistry.list_tools/0`

### Regras
- Se `:enable_browser` estiver falso, `Browser.spec/0` nao deve expor nenhum tool.
- O registry nativo nao deve listar `browser` quando ele estiver indisponivel.
- A descricao de `browser` deve enfatizar uso interativo.
- A descricao de `web_fetch` deve enfatizar leitura textual de URL.

### Criterios de aceite
1. Teste prova que `Browser.spec/0` retorna lista vazia quando `:enable_browser` esta falso.
2. Teste prova que o registry nativo nao expõe `browser` quando desabilitado.
3. Teste prova que `browser` volta a aparecer quando habilitado.

---

## Incremento 2026-03-13 (Recuperar `empty_response` no Primeiro Turno)

### Objetivo
- Evitar erro imediato ao usuario quando o provider encerra o stream vazio em perguntas simples.
- Tentar um fechamento leve antes de desistir com `:empty_response`.

### Interfaces/Public API
- `Pincer.Core.Executor`

### Regras
- Se o stream terminar sem texto final util, sem tools e sem texto visivel em `depth == 0`, o executor deve tentar uma unica recuperacao via `chat_completion`.
- Essa recuperacao deve usar um caminho leve, sem depender de tools.
- Se a recuperacao tambem falhar ou continuar vazia, o erro final continua sendo `:empty_response`.

### Criterios de aceite
1. Teste prova que `stream_completion` vazio seguido de `chat_completion` valido gera `executor_finished`.
2. Teste prova que, sem recuperacao util, o erro continua `:empty_response`.
3. `mix test test/pincer/core/executor_empty_response_test.exs` passa.

---

## Incremento 2026-03-13 (Extrair Prompt Assembly do Executor)

### Objetivo
- Tirar do `Executor` a montagem de prompt que hoje mistura pruning, tempo, memoria narrativa, learnings e recall.
- Deixar esse comportamento testavel fora do loop de execucao.

### Interfaces/Public API
- `Pincer.Core.PromptAssembly.prepare/3`

### Regras
- `PromptAssembly.prepare/3` deve receber `history`, `model_override` e opcoes/dependencias para produzir o `prompt_history` final.
- O modulo deve encapsular:
  - calculo do limite seguro por provider
  - pruning / summary pruning
  - augmentacao do system prompt com tempo, memoria narrativa, learnings e recall
  - resolucao de anexos preguiçosos continua no `Executor` por ora
- O `Executor` deve delegar a montagem de prompt a esse modulo.

### Criterios de aceite
1. Teste prova que `PromptAssembly.prepare/3` injeta tempo, memoria narrativa, learnings e recall no system prompt.
2. Teste prova que `Executor` passa a delegar para `PromptAssembly`.

---

## Incremento 2026-03-13 (Centralizar Policy de Eventos de Canal)

### Objetivo
- reduzir logica imperativa residual nas sessoes de canal
- centralizar em `Core` a classificacao de status textual e o envelope de erro visivel
- remover acoplamento direto do worker de WhatsApp com `ProjectRouter` e `Session.Server`

### Interfaces/Public API
- `Pincer.Core.ChannelEventPolicy.error_message/2`
- `Pincer.Core.ChannelEventPolicy.status_kind/1`

### Regras
- `status_kind/1` deve classificar textos de sub-agente sem depender do canal.
- `error_message/2` deve produzir o envelope user-visible por transporte.
- Telegram e Discord devem usar `ChannelEventPolicy` no roteamento de `agent_error` e `agent_status`.
- WhatsApp deve usar `ProjectFlowDelivery` para avancar/recuperar fluxo de projeto.

### Criterios de aceite
1. Existe teste puro cobrindo `status_kind/1` e `error_message/2`.
2. Telegram e Discord deixam de manter heuristica local duplicada para status textual e erro.
3. WhatsApp deixa de depender diretamente de `ProjectRouter` e `Session.Server`.
4. Testes de sessao relevantes continuam verdes.

---

## Incremento 2026-03-13 (Introduzir Sub-boundary `Pincer.Core.UX`)

### Objetivo
- iniciar a Phase 2 com um fence semantico pequeno e de baixo risco
- tirar `UX.MenuPolicy` e `UX.ModelKeyboard` do exportao do boundary `Pincer.Core`
- transformar `Pincer.Core.UX` em sub-boundary responsavel por seus modulos de UX

### Interfaces/Public API
- `Pincer.Core.UX`
- `Pincer.Core.UX.MenuPolicy`
- `Pincer.Core.UX.ModelKeyboard`

### Regras
- `Pincer.Core.UX` deve declarar `use Boundary` e exportar `MenuPolicy` e `ModelKeyboard`.
- `Pincer.Core` deve continuar exportando `UX` e pode manter re-export temporario de `MenuPolicy` e `ModelKeyboard` enquanto `Channels` ainda depende desses modulos via `Core`.
- O teste de regressao de exports deve cobrir o novo boundary.

### Criterios de aceite
1. Existe teste de boundary cobrindo `lib/pincer/core/ux.ex`.
2. `mix compile` e os testes de UX/boundary passam.
3. O comportamento funcional de menus/keyboard permanece inalterado.

---

## Incremento 2026-03-13 (Recuperacao Explicita de `empty_response`)

### Objetivo
- alinhar a recuperacao de `empty_response` ao padrao do Nullclaw
- remover a heuristica regex de smalltalk
- fazer uma unica segunda tentativa com uma instrucao explicita exigindo resposta visivel ou tool call

### Interfaces/Public API
- `Pincer.Core.EmptyResponseRecoveryPolicy.recovery_prompt/0`
- `Pincer.Core.EmptyResponseRecoveryPolicy.retry_history/1`

### Regras
- a recuperacao leve por `chat_completion` pode ser tentada uma unica vez no primeiro turno quando a resposta final vier vazia.
- a segunda tentativa deve incluir uma instrucao explicita informando que a resposta anterior foi vazia e exigindo uma resposta visivel ao usuario ou a tool call necessaria.
- a instrucao de recuperacao deve orientar o modelo a continuar naturalmente no idioma do usuario, sem mencionar o proprio mecanismo de recovery.
- se a segunda tentativa ainda vier vazia, o `Executor` deve manter `:empty_response`.

### Criterios de aceite
1. Existe teste puro cobrindo a instrucao de recuperacao e a montagem do historico de retry.
2. Pergunta factual tambem pode usar essa unica recuperacao explicita no primeiro turno.
3. Se a segunda tentativa continuar vazia, o resultado permanece `:empty_response`.
4. O modulo continua compilando em Elixir 1.18 sem depender de regex em atributo de modulo.

---

## Incremento 2026-03-13 (Classificar Erros de `web_fetch`)

### Objetivo
- impedir que `web_fetch` despeje dumps brutos de TLS/transporte no contexto do agente
- devolver mensagens curtas e acionaveis para falhas comuns de fetch
- separar classificacao pura de erro do caminho com efeito do tool

### Interfaces/Public API
- `Pincer.Adapters.Tools.WebFetchError.format/1`

### Regras
- erro de TLS com `hostname_check_failed` deve virar mensagem curta sobre mismatch de certificado/host.
- timeout de transporte deve virar mensagem curta de timeout.
- erros nao classificados continuam com fallback generico.

### Criterios de aceite
1. Existe teste puro cobrindo hostname mismatch, timeout e fallback generico.
2. `web_fetch` passa a usar `WebFetchError.format/1`.

---

## Incremento 2026-03-13 (Forcar `tool_only` apos Turno Final Vazio)

### Objetivo
- impedir que um turno pos-tool com resposta final vazia escape como `:empty_response`
- garantir degradacao consistente para `tool_only` quando ja existem resultados de ferramenta

### Interfaces/Public API
- sem nova API publica; ajuste no fechamento do `Pincer.Core.Executor`

### Regras
- se `depth > 0` e ja houver mensagens `tool` no historico logico, resposta final vazia deve resultar em `tool_only`.
- isso vale mesmo quando nao houve `streamed_text` user-visible.

### Criterios de aceite
1. Existe regressao cobrindo tool bem-sucedida seguido de stream vazio.
2. O `Executor` retorna resposta `tool_only` util em vez de `:empty_response`.

---

## Incremento 2026-03-13 (Recuperar `web_fetch` de Hostname Mismatch)

### Objetivo
- fazer `web_fetch` resolver casos em que `https://host` falha por mismatch de certificado, mas o site ainda funciona via browser
- manter a navegacao segura, com validacao de URL e redirects

### Interfaces/Public API
- sem nova API publica externa
- seam interno de HTTP client para teste de `web_fetch`

### Regras
- se `https://host` falhar com `hostname_check_failed`, `web_fetch` pode tentar uma vez `http://host`.
- redirects continuam sendo validados por `validate_url/1`.
- o fallback nao pode pular as protecoes SSRF existentes.

### Criterios de aceite
1. Existe teste cobrindo `https` com hostname mismatch seguido de sucesso por `http`.
2. O tool retorna o conteudo final em vez de erro bruto nesse caso.

---

## Incremento 2026-03-13 (Ensinar Padroes de Resposta para `git` e `gh`)

### Objetivo
- ensinar o agente a fechar respostas uteis apos tools de Git/GitHub
- reduzir casos em que a tool funciona mas o modelo nao produz sintese util
- colocar esse conhecimento em politica pura de grounding, nao em strings soltas no `Executor`

### Interfaces/Public API
- `Pincer.Core.ToolAnswerPatternPolicy.build/1`

### Regras
- quando houver tools de Git/GitHub, o grounding pos-tool deve incluir exemplos de resposta factual.
- exemplos devem cobrir pelo menos:
  - `git_inspect status/log/diff/branches`
  - `github` / `get_issue` / `get_pr` / `list_issues` / `list_prs`
- o grounding deve instruir a resumir sucesso util em vez de responder com erro generico.

### Criterios de aceite
1. Existe teste puro cobrindo deteccao de tools de Git/GitHub e o grounding gerado.
2. O `Executor` passa a anexar essa orientacao ao grounding pos-tool.

---

## Incremento 2026-03-13 (Classificar Erros de `git_inspect`)

### Objetivo
- trocar stderr cru do Git por mensagens curtas e acionaveis
- cobrir os erros de leitura de repo mais comuns antes de endurecer `gh`

### Interfaces/Public API
- `Pincer.Adapters.Tools.GitInspectError.format/1`

### Regras
- `not a git repository` deve virar mensagem estavel e curta.
- `pathspec did not match any files` deve virar erro curto de arquivo ausente.
- `ambiguous argument` / `unknown revision or path` deve virar erro curto de referencia/caminho invalido.
- fallback generico continua existindo para stderr nao classificado.

### Criterios de aceite
1. Existe teste puro cobrindo os erros acima.
2. `git_inspect` usa `GitInspectError.format/1`.
3. Regressao funcional cobre `diff` com `target_path` inexistente.

---

## Incremento 2026-03-13 (Classificar Erros do Tool `github`)

### Objetivo
- trocar erros crus de API/transporte do tool `github` por mensagens curtas e acionaveis
- tornar o client HTTP do tool injetavel para testes reais de erro

### Interfaces/Public API
- `Pincer.Adapters.Tools.GitHubError.format_http/2`
- `Pincer.Adapters.Tools.GitHubError.format_transport/1`

### Regras
- `401` deve virar erro curto de autenticacao/token.
- `403` com rate limit deve virar erro curto de rate limit.
- `404` deve virar erro curto de recurso nao encontrado/sem acesso.
- transport timeout deve virar erro curto de timeout.

### Criterios de aceite
1. Existe teste puro cobrindo `401`, `403 rate limit`, `404` e timeout.
2. Existe teste do tool `github` cobrindo pelo menos um erro HTTP e um de transporte via client injetado.
3. `github.ex` usa o formatter novo.
4. O tool obtem o cliente HTTP via configuracao para manter os testes de erro puros e sem monkeypatch global.

## Incremento 2026-03-13 (Resumo Util para `tool_only` de Git/GitHub)

### Objetivo
- impedir que um turno com tool bem-sucedida de Git/GitHub degrade para um resumo quase inutil quando o modelo falhar no fechamento final
- entregar um resumo minimo e estruturado ao usuario a partir do proprio resultado da tool

### Interfaces/Public API
- `Pincer.Core.ToolResultSummary.summarize/1`
- `Pincer.Core.ToolOnlyOutcomeFormatter.format/1`

### Regras
- quando houver `tool_only` com sucesso de `git_inspect`, `github`, `get_issue` ou `get_pr`, o formatter deve preferir um resumo util em vez de apenas preview bruto.
- resultados JSON de `get_issue` e `get_pr` devem ser reduzidos a campos semanticos principais (`number`, `title`, `state`, `url`).
- `git_inspect` deve priorizar as primeiras linhas nao vazias do resultado, sem despejar diff/log inteiro.
- a mensagem continua explicitando que o modelo nao fechou a resposta final.

### Criterios de aceite
1. Existe teste puro cobrindo resumo estruturado para `get_issue` com payload JSON.
2. Existe teste puro cobrindo resumo util para `git_inspect`.
3. `ToolOnlyOutcomeFormatter` continua destacando erros de tool quando houver falhas.

## Incremento 2026-03-14 (Resumo Util para Colecoes GitHub/MCP em `tool_only`)

### Objetivo
- impedir que respostas degradadas de GitHub/MCP com arrays ou objetos grandes caiam em preview cru quase inutil
- resumir colecoes de issues, PRs, commits, repos e resultados de busca de codigo em poucas linhas semanticas

### Interfaces/Public API
- `Pincer.Core.ToolResultSummary.summarize/1`
- `Pincer.Core.ToolOnlyOutcomeFormatter.format/1`

### Regras
- `list_issues` e `list_prs` com JSON array devem virar lista curta com `#numero`, `titulo`, `state` e `url`.
- `list_commits` deve resumir `sha`, primeira linha da mensagem e data/autor quando presentes.
- `search_code` deve resumir `total_count` e os primeiros itens com `repo`, `path` e `url`.
- `list_repos` deve resumir `full_name`, descricao curta e `html_url`.
- o resumo deve limitar quantidade de itens para nao virar dump.

### Criterios de aceite
1. Existe teste puro cobrindo `list_issues` com array JSON.
2. Existe teste puro cobrindo `list_commits` ou `search_code`.
3. Existe teste end-to-end do executor provando fallback util apos tool de colecao GitHub/MCP seguido de final vazio.

## Incremento 2026-03-14 (Cobertura de Resumo para PRs, Busca de Codigo e Repos)

### Objetivo
- travar em teste as outras colecoes GitHub/MCP que ainda faltavam no fallback util
- garantir que `list_prs`, `search_code` e `list_repos` tambem gerem resposta curta e semantica quando o modelo falhar apos o tool

### Interfaces/Public API
- `Pincer.Core.ToolResultSummary.summarize/1`

### Regras
- `list_prs` deve resumir `#numero`, `titulo`, `state` e `url`.
- `search_code` deve resumir total e os primeiros matches com `repo`, `path` e `url`.
- `list_repos` deve resumir `full_name`, descricao curta e `html_url`.

### Criterios de aceite
1. Existem testes puros cobrindo `list_prs`, `search_code` e `list_repos`.
2. Existe teste end-to-end do executor cobrindo pelo menos um desses casos alem de `list_issues`.
  - `access_count`
  - `inserted_at` como desempate
- Ao retornar memoria semantica, o adapter deve atualizar `access_count` e `last_accessed_at`.
- `forget_memory/1` nao apaga fisicamente o item; marca `forgotten_at` e o remove dos resultados padrao.
- `search_sessions/2` deve retornar hits agrupados ou identificados por `session_id`, permitindo busca cruzada explicita.
- Citacoes devem incluir `line_start/line_end` quando armazenados no metadata do item.

### Criterios de aceite
1. Teste de unidade valida normalizacao dos `memory_type`.
2. Teste de integracao prova que documentos com `importance` maior rankeiam acima de equivalentes menos importantes.
3. Teste de integracao prova que `forget_memory/1` esconde o item por padrao, mas ele continua recuperavel com `include_forgotten: true`.
4. Teste de integracao prova que `search_sessions/2` encontra hits em sessoes diferentes e preserva citacao por sessao.
5. Teste de integracao prova que o `Archivist` persiste snippets com `memory_type`, `importance` e `session_id`.
6. Suite completa permanece verde.

---

## Incremento 2026-03-10 (Migracao Direta para Postgres + pgvector)

### Objetivo
...

---

## Incremento 2026-03-10 (P3B: relatorios e explain de memoria)

### Objetivo
- Transformar a telemetria de memoria em observabilidade operacional consumivel por humanos.
- Expor um relatorio resumido de runtime + persistencia de memoria.
- Expor um comando de explain que mostre, para uma query, o que o recall consideraria e por que.

### Interfaces/Public API
- `Pincer.Core.MemoryDiagnostics.report/1`
- `Pincer.Core.MemoryDiagnostics.explain/2`
- `Pincer.Core.MemoryRecall.explain/2`
- `Pincer.Ports.Storage.memory_report/1`
- `mix pincer.memory.report`
- `mix pincer.memory.explain --query "..."`

### Regras
- `MemoryDiagnostics.report/1` deve combinar:
  - snapshot atual de `Pincer.Core.MemoryObservability`
  - resumo persistente vindo do adapter de storage
- O resumo persistente deve incluir no minimo:
  - total de documentos de memoria
  - total de documentos esquecidos
  - contagem por `memory_type`
  - top memórias por acesso/importancia
  - top sessoes por quantidade de memorias documentais
- `MemoryRecall.explain/2` deve reutilizar a mesma logica de elegibilidade, sanitizacao e recuperacao usada por `build/2`, mas retornando detalhes por fonte (`messages`, `documents`, `semantic`) sem perder o bloco final de prompt.
- `MemoryDiagnostics.explain/2` deve:
  - aceitar query explicita
  - retornar o explain detalhado do recall
  - anexar sessoes relacionadas via `search_sessions/2`
- `mix pincer.memory.report` deve imprimir um resumo legivel de:
  - recall/search runtime
  - distribuicao por fonte
  - contagem persistente por tipo
  - top memórias
  - top sessoes
- `mix pincer.memory.explain` deve:
  - exigir `--query`
  - aceitar `--workspace-path`, `--limit`, `--session-id`
  - aceitar `--no-semantic` para evitar embeddings remotos
  - imprimir elegibilidade, contagem por fonte, hits retornados e sessoes relacionadas
- Comandos de diagnostico nao devem poluir a telemetria operacional do runtime por padrao.

### Criterios de aceite
1. Teste de unidade prova que `MemoryDiagnostics.report/1` e `MemoryDiagnostics.explain/2` agregam corretamente dependencias injetadas.
2. Teste de regressao prova que `MemoryRecall.explain/2` retorna hits por fonte e preserva sanitizacao/compactacao do prompt.
3. Teste de integracao prova que `mix pincer.memory.report` imprime resumo com runtime e persistencia.
4. Teste de integracao prova que `mix pincer.memory.explain --no-semantic` explica uma query sem depender de rede.
5. `mix format`, `mix compile` e os testes relevantes passam.

---

## Incremento 2026-03-10 (Retrieval v2: ranking hibrido, graph boost e diversidade)

### Objetivo
- Elevar o recall do Pincer do nivel `FTS + semantic stopgap` para um retrieval mais competitivo.
- Combinar sinais textuais e semanticos de forma hibrida, sem dupla contagem ingênua.
- Introduzir `graph boost` quando um documento indexado estiver ligado a historico de bug/fix no grafo.
- Reduzir redundancia no bloco final de recall, privilegiando diversidade de sessao e tipo de memoria.

### Interfaces/Public API
- `Pincer.Core.MemoryRecall.explain/2`
- `Pincer.Ports.Storage.search_documents/3`
- `Pincer.Ports.Storage.search_similar/3`
- `Pincer.Storage.Adapters.Postgres.memory_report/1`

### Regras
- Hits documentais retornados por `search_documents/3` e `search_similar/3` devem carregar metadados suficientes para merge hibrido:
  - `memory_type`
  - `session_id`
  - `signal`
  - `signal_score`
  - `score_components`
- O score final por sinal deve considerar:
  - score bruto normalizado do sinal (`text` ou `semantic`)
  - importancia
  - acesso historico
  - frescor com decay temporal
  - `graph_boost` quando o `path` do documento coincidir com um `file` ligado a bugs/fixes relevantes
- `MemoryRecall` deve mesclar hits textuais e semanticos do mesmo `source`, somando sinais distintos e contando boosts de metadata apenas uma vez.
- O bloco final de recall deve aplicar uma selecao gulosa com penalidade leve para excesso de hits da mesma sessao/tipo de memoria.
- `MemoryDiagnostics.explain/2` deve refletir os hits ja reranqueados pelo retrieval v2.

### Criterios de aceite
1. Teste de integracao prova que um documento com mesmo conteudo, mas ligado ao grafo de bug/fix correto, rankeia acima de equivalente sem ligacao.
2. Teste de unidade/integracao prova que `MemoryRecall.explain/2` mescla hit textual e hit semantico do mesmo documento em um unico resultado mais forte.
3. Teste de regressao prova que o explain continua mostrando `messages/documents/semantic` por fonte, mas o bloco final usa a ordem reranqueada e deduplicada.
4. Suite relevante de memoria continua verde.

---

## Incremento 2026-03-10 (Retrieval v2.1: recall relacional do grafo)

### Objetivo
- Fazer o grafo participar diretamente do recall, nao apenas como `boost` indireto.
- Recuperar historico relacional de `bug/fix/file` para queries de incidente.
- Injetar evidencias compactas de grafo no prompt com citacao clara, sem inundar o bloco final.

### Interfaces/Public API
- `Pincer.Ports.Storage.search_graph_history/2`
- `Pincer.Core.MemoryRecall.explain/2`
- `Pincer.Core.MemoryDiagnostics.explain/2`

### Regras
- `search_graph_history/2` deve retornar entradas estruturadas contendo:
  - `bug`
  - `fix`
  - `file`
  - `source`
  - `citation`
  - `score`
- A busca do grafo deve priorizar matches em:
  - descricao do bug
  - resumo do fix
  - caminho do arquivo
- `MemoryRecall` deve consultar o grafo apenas para queries elegiveis e tipicamente incidentais.
- Hits de grafo devem aparecer em `source_hits.graph` e `source_counts.graph`.
- O bloco final deve poder incluir hits de grafo, mas com diversidade e sem duplicar excessivamente informacao ja coberta por documentos.
- `MemoryDiagnostics.explain/2` deve expor `graph` na resposta.

### Criterios de aceite
1. Teste de integracao prova que `search_graph_history/2` retorna historico relevante para query de incidente.
2. Teste de regressao prova que `MemoryRecall.explain/2` inclui hits de grafo e o prompt final menciona a citacao relacional.
3. Teste de Mix task ou diagnostico prova que `pincer.memory.explain` mostra `graph=N` quando houver match.
- Migrar o storage principal do Pincer de SQLite para PostgreSQL.
- Substituir embeddings binarios por colunas vetoriais com `pgvector`.
- Preservar a API publica do port `Pincer.Ports.Storage`.
- Trocar busca textual baseada em SQLite FTS5 por FTS do PostgreSQL.
- Remover o acoplamento operacional a arquivos `db/*.db` no onboarding/config.

### Escopo
- `mix.exs`
- `config/*.exs`
- `config.yaml`
- `lib/pincer/repo.ex`
- `lib/pincer/config.ex`
- `lib/pincer/storage/message.ex`
- `lib/pincer/storage/graph/node.ex`
- `lib/pincer/storage/adapters/*.ex`
- `priv/repo/migrations/*.exs`
- `docker-compose.yml`
- `Dockerfile`
- `infrastructure/docker/entrypoint.sh`
- testes de storage/onboarding/smoke relevantes

### Interfaces/Public API
- `Pincer.Infra.Repo`
  - passa a usar `Ecto.Adapters.Postgres`
- `Pincer.Storage.Graph.Node.embedding`
  - passa de `:binary` para `Pgvector.Ecto.Vector`
- `Pincer.Storage.Message.embedding`
  - passa de `:binary` para `Pgvector.Ecto.Vector`
- `Pincer.Ports.Storage`
  - mantem callbacks publicos atuais sem alterar assinatura

### Regras
- A migracao e direta; nao deve existir camada de compatibilidade com SQLite no caminho principal.
- O banco padrao do projeto passa a ser PostgreSQL.
- A extensao `vector` deve ser habilitada nas migrations.
- As colunas de embedding devem usar tipo vetorial nativo do `pgvector`, sem serializacao manual com `term_to_binary`.
- A busca textual deve usar capacidades nativas do PostgreSQL.
- O onboarding/config padrao deve gerar configuracao de Postgres, nao caminho de arquivo SQLite.
- O stack local via Docker Compose deve incluir um servico de Postgres pronto para desenvolvimento.

### Criterios de aceite
1. `mix deps.get` resolve `postgrex` e `pgvector`.
2. O `Repo` sobe com adapter Postgres e configuracao de host/porta/database.
3. `index_document/index_memory/search_similar` usam vetor nativo e nao mais cosine manual em Elixir.
4. `search_messages/search_documents` usam FTS do PostgreSQL.
5. Onboarding, config defaults e smoke tests deixam de assumir `db/*.db`.
6. Suite relevante permanece verde com Postgres disponivel.

---

## Incremento 2026-03-10 (Memoria P3A: observabilidade basica)

### Objetivo
- Adicionar observabilidade basica ao pipeline de memoria sem deps novas.
- Medir recall operacional no runtime com eventos de telemetry.
- Disponibilizar um snapshot local e deterministico para diagnostico de memoria.

### Interfaces/Public API
- `Pincer.Core.Telemetry.emit_memory_search/2`
- `Pincer.Core.Telemetry.emit_memory_recall/2`
- `Pincer.Core.MemoryObservability.start_link/1`
- `Pincer.Core.MemoryObservability.snapshot/0`
- `Pincer.Core.MemoryObservability.reset/0`
- `Pincer.Core.MemoryRecall.build/2`
  - passa a emitir telemetry de busca e recall

### Regras
- O pipeline de recall deve emitir um evento `[:pincer, :memory, :search]` para cada fonte consultada:
  - `messages`
  - `documents`
  - `semantic`
- Cada evento de busca deve incluir no minimo:
  - `duration_ms`
  - `hit_count`
  - `count`
  - metadata com `source`, `outcome`, `session_id` e `query_length` quando disponivel
- O pipeline de recall deve emitir um evento consolidado `[:pincer, :memory, :recall]` por build contendo no minimo:
  - `duration_ms`
  - `total_hits`
  - `message_hits`
  - `document_hits`
  - `semantic_hits`
  - `prompt_chars`
  - `learnings_count`
- `MemoryObservability` deve agregar estes eventos localmente e expor snapshot deterministico com:
  - contadores totais
  - medias simples
  - breakdown por fonte
  - ultimo evento de busca
  - ultimo evento de recall
- O snapshot deve ser seguro para testes:
  - `reset/0` limpa acumuladores
  - quando nao houver eventos, `snapshot/0` retorna zeros/defaults coerentes
- Nenhum evento de observabilidade deve incluir o texto cru da query ou conteudo da memoria.

### Criterios de aceite
1. Teste de unidade prova que `emit_memory_search/2` e `emit_memory_recall/2` publicam eventos com contrato minimo.
2. Teste de unidade prova que `MemoryObservability.snapshot/0` agrega contadores e medias corretamente.
3. Teste de integracao prova que `MemoryRecall.build/2` emite eventos de busca e recall e atualiza o snapshot.
4. Teste de regressao prova que `snapshot/0` retorna defaults estaveis apos `reset/0`.
5. Suite relevante permanece verde.

---

## Incremento 2026-03-10 (Docker DX: auto-onboard idempotente)

### Objetivo
- Reduzir o setup local para um fluxo principal com `docker compose up --build -d`.
- Fazer o container do app executar onboarding apenas quando o workspace ainda nao estiver preparado.
- Persistir `workspaces/` no host para que scaffold e agentes sobrevivam a recreacoes do container.

### Interfaces/Public API
- `Pincer.Core.Onboard.onboarded?/1`
- `mix pincer.onboard --if-missing`
- `infrastructure/docker/entrypoint.sh`

### Regras
- `Onboard.onboarded?/1` deve retornar `true` apenas quando os artefatos minimos de onboarding existirem no root informado:
  - `config.yaml`
  - `workspaces/`
  - `sessions/`
  - `memory/`
  - `workspaces/.template/.pincer/BOOTSTRAP.md`
  - `workspaces/.template/.pincer/MEMORY.md`
  - `workspaces/.template/.pincer/HISTORY.md`
- `mix pincer.onboard --if-missing` deve:
  - executar onboarding normal quando o workspace ainda nao estiver preparado;
  - encerrar sem alterar arquivos quando o workspace ja estiver onboarded.
- O entrypoint Docker deve rodar onboarding idempotente antes de `ecto.create/migrate`.
- O `docker-compose.yml` deve persistir `workspaces/` no host e permitir escrita em `config.yaml`.

### Criterios de aceite
1. Teste de unidade prova `Onboard.onboarded?/1` para casos onboarded e incompleto.
2. Teste do mix task prova que `--if-missing` cria arquivos quando necessario e faz skip quando ja esta onboarded.
3. README passa a documentar `docker compose up --build -d` como caminho principal.
4. Suite relevante permanece verde.

---

## Incremento 2026-03-10 (Memoria P3B: relatorios e explain)

### Objetivo
- Transformar a observabilidade basica de memoria em ferramentas operacionais para humano.
- Expor um relatorio de saude/inventario da memoria via Mix task.
- Expor uma explicacao de recall por query via Mix task, usando as APIs de storage ja existentes.

### Interfaces/Public API
- `Pincer.Core.MemoryDiagnostics.report/1`
- `Pincer.Core.MemoryDiagnostics.explain/2`
- `mix pincer.memory.report`
- `mix pincer.memory.explain --query "..."`

### Regras
- `Pincer.Core.MemoryDiagnostics.report/1` deve retornar um mapa deterministico contendo, no minimo:
  - `snapshot` vindo de `Pincer.Core.MemoryObservability.snapshot/0`
  - `health` com indicadores derivados, incluindo:
    - `avg_hits_per_recall`
    - `empty_recall_rate`
    - `search_hit_rate`
  - `inventory` com:
    - `total_memories`
    - `forgotten_memories`
    - `by_type`
    - `top_memories`
  - `recent_learnings`
  - `recent_history`
- O inventario deve ser calculado a partir do banco atual (`nodes` do tipo `document`) sem criar nova dependencia.
- `Pincer.Core.MemoryDiagnostics.explain/2` deve aceitar filtros por:
  - `limit`
  - `session_id`
  - `memory_type`
  - `include_forgotten`
- `explain/2` deve retornar, no minimo:
  - `eligible?` usando `Pincer.Core.MemoryRecall.eligible_query?/1`
  - `documents` via `search_documents/3`
  - `sessions` via `search_sessions/2`
  - `semantic` via `search_similar/3` quando embeddings estiverem disponiveis
  - `notes` quando alguma fonte for ignorada ou falhar
- `mix pincer.memory.report` deve imprimir um relatorio legivel contendo:
  - contadores principais
  - saude do recall
  - top memórias
  - learnings/historico recentes
- `mix pincer.memory.explain` deve:
  - exigir `--query`
  - imprimir filtros aplicados
  - mostrar hits de documentos, sessoes e semanticos com score/citacao quando houver
  - informar quando semantic search for pulada

### Criterios de aceite
1. Teste de unidade valida que `MemoryDiagnostics.report/1` combina snapshot e inventario persistido corretamente.
2. Teste de unidade valida que `MemoryDiagnostics.explain/2` respeita filtros e anota fallback/skip semantico.
3. Teste de Mix task prova que `mix pincer.memory.report` imprime um relatorio operacional com os principais contadores.
4. Teste de Mix task prova que `mix pincer.memory.explain --query ...` imprime hits e falha sem `--query`.
5. Suite relevante permanece verde.

---

## 0. Incremento 2026-02-22 (Onboard + DB em `./db`)

### Objetivo
- Entregar base de onboarding linux-style (`mix pincer.onboard`).
- Padronizar a configuracao inicial de banco do projeto.

### Interfaces Públicas
```elixir
Pincer.Core.Onboard.defaults/0
Pincer.Core.Onboard.plan/1
Pincer.Core.Onboard.apply_plan/2
```

```bash
mix pincer.onboard
mix pincer.onboard --non-interactive --yes
mix pincer.onboard --non-interactive --db-name pincer_custom
```

### Critérios de aceite
1. `mix pincer.onboard --non-interactive --yes` cria `config.yaml`, `sessions/` e `memory/`.
2. Config padrão aponta para Postgres em `localhost:5432`, database `pincer`.
3. `config/dev.exs` e `config/test.exs` usam defaults de Postgres coerentes com o ambiente local.
4. Implementação coberta por testes em:
   - `test/pincer/core/onboard_test.exs`
   - `test/mix/tasks/pincer.onboard_test.exs`
   - `test/pincer/config/db_defaults_test.exs`

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
    - usar `--db-name`, `--provider` ou `--model` sem capability `config_yaml` deve falhar com erro explícito.
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

## Isolamento de Estado Cognitivo por Workspace (SPR-084)

### Problema

- `IDENTITY.md`, `SOUL.md`, `USER.md`, `BOOTSTRAP.md`, `MEMORY.md`, `HISTORY.md` e logs de sessão ainda vazam para a raiz do projeto;
- `Session.Server`, `Session.Logger` e `Archivist` assumem paths globais;
- sub-agentes hoje não recebem workspace próprio, então herdam cwd global e não ficam isolados.

### Objetivo

- mover o estado cognitivo do Pincer para `workspaces/<agent_id>/.pincer/`;
- garantir que cada agente trabalhe dentro do seu próprio workspace;
- permitir bootstrap apenas para agentes raiz;
- impedir que sub-agentes entrem no rito de bootstrap.

### Contrato

- todo agente raiz usa `workspaces/<session_id>/.pincer/` como diretório canônico para:
  - `BOOTSTRAP.md`
  - `IDENTITY.md`
  - `SOUL.md`
  - `USER.md`
  - `MEMORY.md`
  - `HISTORY.md`
  - `sessions/session_<id>.md`
- sub-agentes usam `workspaces/<agent_id>/.pincer/`, mas:
  - não recebem `BOOTSTRAP.md`;
  - podem herdar `IDENTITY.md`, `SOUL.md` e `USER.md` do workspace pai como seed inicial;
  - mantêm `MEMORY.md`, `HISTORY.md` e logs próprios.
- `Session.Server` não deve mais ler persona/memória da raiz do repo para operação normal;
- onboarding deve provisionar scaffold/template compatível com a nova convenção, sem recriar `MEMORY.md` ou `HISTORY.md` na raiz.

### Implementação

- introduzir um resolvedor central de paths do agente;
- `Session.Server.init/1` garante o `.pincer/` do workspace antes de montar o system prompt;
- `bootstrap_active?/2` passa a considerar apenas `workspaces/<id>/.pincer/BOOTSTRAP.md` e a ausência de `IDENTITY.md` + `SOUL.md` naquele mesmo workspace;
- `Session.Logger` grava em `workspaces/<id>/.pincer/sessions/`;
- `Archivist` consolida contra `workspaces/<id>/.pincer/MEMORY.md` e `workspaces/<id>/.pincer/HISTORY.md`;
- `dispatch_agent` passa o `workspace_path` do pai ao sub-agente para que ele crie um workspace isolado e herde apenas persona, nunca bootstrap.

### Critério de aceite

1. sessão raiz monta prompt usando apenas arquivos de `workspaces/<session_id>/.pincer/`;
2. logs de sessão passam a existir somente em `workspaces/<session_id>/.pincer/sessions/`;
3. sub-agente recebe workspace isolado e não cria `BOOTSTRAP.md`;
4. onboarding deixa de escrever `MEMORY.md` e `HISTORY.md` na raiz;
5. testes de regressão cobrem seed de workspace raiz, seed de sub-agente e resolução do prompt local.
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

### Robustez de Tool Calls + UX Telegram Native-First (SPR-073)
- Objetivo:
  - eliminar `FunctionClauseError` no executor quando providers retornam `tool_calls.function.arguments` em formato não textual (ex.: mapa já decodificado);
  - reduzir ruído visual no Telegram mobile removendo teclado persistente duplicado de `Menu` por padrão;
  - manter compatibilidade retroativa para tool calls em JSON string.
- Interfaces públicas afetadas:
  - `Pincer.Core.Executor` (normalização de tool call antes da execução)
  - `Pincer.Channels.Telegram.menu_reply_markup/0`
- Regras v1:
  - executor deve aceitar argumentos de tool call em múltiplos formatos:
    - JSON string (`"{\"k\":\"v\"}"`)
    - mapa (`%{"k" => "v"}` / `%{k: "v"}`)
    - `nil` (normaliza para `%{}`)
  - tool call malformado não deve derrubar o ciclo de execução; deve retornar erro funcional no conteúdo da mensagem `tool`;
  - no Telegram, `menu_reply_markup/0` deve operar em modo native-first por padrão:
    - remover teclado custom inferior (`remove_keyboard: true`);
    - manter comandos nativos (`/menu`, `/status`, etc.) como affordance principal.
- Critérios de aceite:
  1. fluxo com `tool_calls` contendo `arguments` como mapa não gera `FunctionClauseError`;
  2. executor continua funcionando para `arguments` em JSON string;
  3. respostas de fallback no Telegram deixam de exibir teclado persistente inferior por padrão;
  4. cobertura de testes para os dois contratos (executor + Telegram markup).

### Robustez de Histórico de Tools + Cooldown Config Fail-Safe (FIX-074)
- Objetivo:
  - evitar falha de provedor (`400 Tool type cannot be empty`) no segundo turno de execução de ferramentas;
  - impedir `FunctionClauseError` em fluxos de falha terminal quando configs de cooldown/retry chegam em formato de lista não-keyword.
- Interfaces públicas afetadas:
  - `Pincer.Core.Executor` (montagem de `assistant.tool_calls` no histórico reenviado)
  - `Pincer.LLM.Client` (normalização de leitura de `:llm_retry`)
  - `Pincer.Core.LLM.CooldownStore` (normalização de leitura de `:llm_cooldown`)
  - `Pincer.Core.AuthProfiles` (normalização de leitura de `:auth_profile_cooldown`)
- Regras v1:
  - `tool_calls` persistidos pelo executor devem sempre incluir `"type": "function"` quando ausente no delta;
  - leitura de config com shape lista deve ser fail-safe:
    - listas keyword continuam suportadas;
    - listas não-keyword não podem explodir `Keyword.get/3`;
    - em caso inválido, usar defaults.
- Critérios de aceite:
  1. ciclo de tool call em streaming preserva/enriquece `tool_calls.type` antes da próxima chamada ao LLM;
  2. cenário com erro HTTP terminal (`400`) não gera `FunctionClauseError` mesmo com `:llm_cooldown`/`:auth_profile_cooldown`/`:llm_retry` em lista não-keyword;
  3. suíte de regressão cobre os dois contratos acima.

### Pairing Persistente + Fluxo Out-of-Band (FIX-075)
- Objetivo:
  - tornar o estado de pairing persistente entre reinícios do processo/container;
  - remover auto-liberação por código exibido no mesmo canal bloqueado;
  - aproximar UX de pairing do fluxo OpenClaw (código obtido fora do chat bloqueado).
- Interfaces públicas afetadas:
  - `Pincer.Core.Pairing` (persistência de pending/pairs e emissão de código para operador)
  - `Pincer.Core.AccessPolicy.authorize_dm/3` (mensagem de pairing sem revelar código)
  - mensagens de ajuda em comandos `/pair` de Telegram/Discord.
- Regras v1:
  - pairing deve persistir em store local baseado em arquivo (`dets`) por padrão;
  - `Pairing.reset/0` deve limpar estado em memória e no store persistente;
  - em `dm_policy: pairing`, mensagem de bloqueio:
    - não deve conter o código numérico;
    - deve orientar solicitação de código ao operador e uso de `/pair <codigo>`;
  - código deve continuar disponível ao operador via logs/evento administrativo out-of-band.
- Critérios de aceite:
  1. após aprovação de pairing, o sender continua pareado após recriação das tabelas runtime;
  2. mensagem de negação do `AccessPolicy` em `pairing` não expõe código de 6 dígitos;
  3. testes cobrem persistência e contrato de UX sem código no canal bloqueado.

### `/models` orientado a `config.yaml` (FIX-076)
- Objetivo:
  - alinhar o comando `/models` com a fonte de verdade operacional (`config.yaml`);
  - evitar listagem de providers/modelos vindos apenas de defaults estáticos de build;
  - manter compatibilidade com fallback legado quando `llm` não estiver disponível.
- Interfaces públicas afetadas:
  - `Pincer.LLM.Client.list_providers/0`
  - `Pincer.LLM.Client.list_models/1`
- Regras v1:
  - `/models` deve priorizar a estrutura carregada de `config.yaml` via `Application.get_env(:pincer, :llm)`;
  - ao derivar registry de `:llm`:
    - ignorar a chave seletora `provider`;
    - considerar apenas entradas de provider cujo valor seja mapa;
  - se `:llm` estiver ausente/inválido/vazio, manter fallback para `:llm_providers`.
- Critérios de aceite:
  1. `list_providers/0` retorna apenas providers definidos sob `llm.<provider>` em `config.yaml` quando `:llm` está presente;
  2. `list_models/1` resolve `default_model`/`models`/`model_list` a partir de `:llm` quando disponível;
  3. fallback legado para `:llm_providers` permanece funcional quando `:llm` não está disponível.

### SafeShell com Perfil Dinâmico por Stack (SPR-074 / AutoClaude v1)
- Objetivo:
  - iniciar integração das melhorias do Auto-Claude com um perfil dinâmico de comandos do `SafeShell`;
  - manter postura fail-closed e validação de path existente;
  - habilitar comandos úteis por stack detectada no workspace, sem abrir superfície ampla.
- Interfaces públicas afetadas:
  - `Pincer.Core.Tooling.CommandProfile` (novo)
  - `Pincer.Tools.SafeShell.approved_command_allowed?/2`
  - `Pincer.Tools.SafeShell.execute/1` (validação dinâmica)
- Regras v1:
  - detecção de stack por artefatos no workspace (`mix.exs`, `package.json`, `Cargo.toml`, `pyproject.toml`/`requirements*.txt`);
  - perfil dinâmico v1 com comandos adicionais estritamente permitidos:
    - `elixir`: `mix format`, `mix pincer.security_audit`, `mix pincer.doctor`
    - `node`: `npm test`
    - `rust`: `cargo test`, `cargo check`
    - `python`: `pytest`
  - comandos dinâmicos devem passar pela mesma validação de args/path já existente (`unsafe_generic_arg?/2`);
  - ausência de stack compatível mantém comportamento atual (fallback para whitelist estático).
- Critérios de aceite:
  1. comandos dinâmicos válidos são aceitos somente quando a stack correspondente é detectada no `workspace_root`;
  2. comandos dinâmicos continuam bloqueando args/path inseguros (absoluto, traversal, symlink escape etc.);
  3. sem artefatos de stack, comandos dinâmicos não são aceitos (fail-closed);
  4. cobertura de testes para `CommandProfile` e para integração no `SafeShell`.

### SafeShell com Scripts Dinâmicos do Projeto (SPR-075 / AutoClaude v2)
- Objetivo:
  - expandir a integração Auto-Claude no `SafeShell` para considerar scripts reais do workspace;
  - reduzir prompts de aprovação para comandos legítimos e específicos do projeto;
  - manter validação de args/path e fail-closed.
- Interfaces públicas afetadas:
  - `Pincer.Core.Tooling.CommandProfile.dynamic_command_prefixes/1`
  - `Pincer.Tools.SafeShell.approved_command_allowed?/2`
- Regras v1:
  - detectar scripts `npm run <script>` em `package.json` (`scripts` map);
  - detectar targets de `make <target>` em `Makefile` (targets simples com sufixo `:`);
  - adicionar somente prefixes explícitos derivados do workspace atual;
  - JSON inválido, `scripts` malformado ou ausência de arquivo devem degradar para lista vazia (sem crash).
- Critérios de aceite:
  1. `npm run <script>` é aceito apenas quando `<script>` existe no `package.json` local;
  2. `make <target>` é aceito apenas quando `<target>` existe no `Makefile` local;
  3. scripts/targets inexistentes continuam bloqueados com aprovação;
  4. args perigosos continuam bloqueados mesmo em comandos dinâmicos de script.

### SafeShell com Runners de Scripts e Shell Scripts Locais (SPR-076 / AutoClaude v3)
- Objetivo:
  - ampliar a integração Auto-Claude no `SafeShell` para cobrir runners comuns de scripts Node;
  - reduzir aprovações em workflows de projeto com `yarn`, `pnpm` e `bun`;
  - permitir execução de shell scripts locais do root do workspace com postura fail-closed.
- Interfaces públicas afetadas:
  - `Pincer.Core.Tooling.CommandProfile.dynamic_command_prefixes/1`
  - `Pincer.Tools.SafeShell.approved_command_allowed?/2`
- Regras v1:
  - derivar scripts de `package.json` (`scripts` map) e permitir:
    - `yarn run <script>`
    - `pnpm run <script>`
    - `bun run <script>`
    - (mantém `npm run <script>` já existente);
  - detectar shell scripts locais do root com nomes seguros (`*.sh`, `*.bash`) e permitir apenas `./<script>`;
  - não aceitar nomes inválidos (vazios, com whitespace, com segmentos de path ou formatos inseguros);
  - ausência/erro de leitura de arquivos deve degradar para lista vazia sem crash.
- Critérios de aceite:
  1. `yarn run <script>`, `pnpm run <script>` e `bun run <script>` só são aceitos se `<script>` existir no `package.json` local;
  2. `./<script>.sh` e `./<script>.bash` só são aceitos quando o arquivo existir no root do workspace;
  3. script/runner inexistente continua bloqueado com aprovação;
  4. args perigosos continuam bloqueados mesmo nesses comandos dinâmicos.

### Auto-envio de artefatos Markdown ao usuário (FIX-077)
- Objetivo:
  - garantir que todo artefato `.md` produzido/atualizado durante execução de tools seja enviado automaticamente ao usuário;
  - remover dependência de instruções em prompt para divulgação de documentos gerados.
- Interfaces públicas afetadas:
  - `Pincer.Core.Executor.run/4`
  - `Pincer.Core.Executor.execute_tool_via_registry/4`
- Regras v1:
  - iniciar snapshot de arquivos markdown (`*.md`) no começo do ciclo do executor;
  - após cada execução de tool, detectar markdown novo ou modificado no workspace;
  - para cada arquivo detectado, emitir atualização de status para sessão contendo:
    - path relativo do arquivo;
    - conteúdo markdown (com truncamento seguro quando muito grande);
  - falhas de leitura/snapshot não podem quebrar o ciclo do executor (fail-safe).
- Critérios de aceite:
  1. quando uma tool cria ou altera `.md`, o usuário recebe mensagem automática sem novo prompt;
  2. markdown sem mudança não gera reenvio redundante no mesmo ciclo;
  3. fluxo de execução de tools continua funcional e coberto por teste de regressão no executor.

### Kanban Operacional por Comando (`/kanban` e `/project`) (SPR-077)
- Objetivo:
  - entregar visualização operacional do projeto por comando sem depender de prompt;
  - expor quadro com contexto DDD/TDD para orientar execução de sprint;
  - garantir paridade de acesso em Telegram e Discord.
- Interfaces públicas afetadas:
  - `Pincer.Core.ProjectBoard` (novo)
  - `Pincer.Core.UX.commands/0`
  - `Pincer.Core.UX.resolve_shortcut/1`
  - `Pincer.Channels.Telegram.handle_command/4`
  - `Pincer.Channels.Discord.handle_command/2` e `handle_slash_command/1`
- Regras v1:
  - `/kanban` retorna board renderizado a partir de `TODO.md`:
    - contagem de itens concluídos (`- [x]`) e pendentes (`- [ ]`);
    - lista curta de pendentes e concluídos recentes;
    - seção explícita de fluxo DDD/TDD (`Spec -> Contract -> Red -> Green -> Refactor -> Review -> Done`);
  - `/project` atua como alias inicial para `/kanban` (mesmo conteúdo v1);
  - leitura de `TODO.md` ausente/inválida deve falhar de forma amigável sem crash.
- Critérios de aceite:
  1. `kanban`/`/kanban` e `project`/`/project` resolvem por shortcut no core UX;
  2. Telegram e Discord respondem aos comandos com board textual;
  3. testes cobrem parser/render do board e roteamento básico de comando nos canais.

### Container Runtime com `TODO.md` para `/kanban` (FIX-078)
- Objetivo:
  - garantir que o board de `/kanban` e `/project` funcione também no container;
  - evitar fallback "Kanban unavailable: TODO.md not found in workspace" em runtime Docker.
- Interfaces públicas afetadas:
  - `Dockerfile` (builder/runtime artifacts)
- Regras v1:
  - incluir `TODO.md` no estágio de build;
  - copiar `TODO.md` para a imagem final de runtime.
- Critérios de aceite:
  1. container final possui `/app/TODO.md`;
  2. `Pincer.Core.ProjectBoard.render/0` executado dentro do container retorna board (não fallback de arquivo ausente).

### Orientação Explícita DDD/TDD no `/project` (SPR-078)
- Objetivo:
  - tornar o comando `/project` um painel de orientação prática de execução;
  - explicitar no texto os checkpoints de DDD e TDD para cada ciclo de implementação;
  - manter `/kanban` como visão enxuta de progresso.
- Interfaces públicas afetadas:
  - `Pincer.Core.ProjectBoard.render/1`
  - `Pincer.Channels.Telegram.handle_command/4`
  - `Pincer.Channels.Discord.handle_command/2`
- Regras v1:
  - `/kanban` permanece mostrando quadro operacional (done/pending + fluxo);
  - `/project` passa a mostrar:
    - board operacional;
    - seção `DDD Checklist` com itens mínimos de domínio/contrato;
    - seção `TDD Checklist` com itens mínimos `Red -> Green -> Refactor`;
    - seção `Next Action` orientando o próximo passo operacional.
- Critérios de aceite:
  1. `/project` responde com texto contendo `DDD Checklist` e `TDD Checklist`;
  2. `/kanban` continua funcional sem se tornar verboso;
  3. testes cobrem renderização diferenciada e roteamento de `project` em Telegram/Discord.

### Orquestração Multi-Agente Adaptativa em `/project` (SPR-079)
- Objetivo:
  - transformar `/project` em fluxo de descoberta guiada por um gestor de projeto;
  - suportar projetos de software e não-software sem impor DDD/TDD em casos inadequados;
  - expor kanban por sessão a partir do plano gerado no fluxo de projeto.
- Interfaces públicas afetadas:
  - `Pincer.Core.ProjectOrchestrator` (novo)
  - `Pincer.Channels.Telegram.UpdatesProvider.handle_command/4`
  - `Pincer.Channels.Discord.Consumer.handle_command/2`
  - `Pincer.Core.ProjectBoard.render/1` (reuso para fallback)
- Regras v1:
  - `/project` inicia um wizard textual com etapas mínimas:
    - objetivo;
    - tipo de projeto (`software` ou `nao-software`);
    - contexto/escopo;
    - critério de sucesso.
  - ao concluir o wizard, o gestor compõe plano multi-agente:
    - `Architect`: escopo e critérios;
    - `Coder`: backlog inicial acionável;
    - `Reviewer`: checklist de validação.
  - para `software`, manter orientação DDD/TDD no plano;
  - para `nao-software`, usar trilha de pesquisa/validação sem jargão de engenharia de software.
  - `/kanban` deve mostrar board por sessão quando existir plano ativo;
    se não existir, manter fallback atual baseado em `TODO.md`.
- Critérios de aceite:
  1. `/project` deixa de ser saída estática e passa a solicitar requisitos;
  2. mensagens subsequentes do usuário, durante o wizard, avançam o estado do projeto;
  3. projetos não-software não exibem `DDD Checklist`/`TDD Checklist`;
  4. `/kanban` apresenta itens do projeto da sessão quando disponível;
  5. testes cobrem fluxo guiado, adaptação por tipo e integração nos canais.

### Branch Automática por Projeto + Roteamento Core-first (SPR-080)
- Objetivo:
  - criar branch Git por projeto ao finalizar o wizard do `/project`;
  - mover decisão de fluxo `/project`/`/kanban` para o core, reduzindo lógica nos adapters de canal.
- Interfaces públicas afetadas:
  - `Pincer.Core.ProjectOrchestrator`
  - `Pincer.Core.ProjectRouter` (novo)
  - `Pincer.Core.ProjectGit` (novo)
  - `Pincer.Channels.Telegram.UpdatesProvider`
  - `Pincer.Channels.Discord.Consumer`
- Regras v1:
  - ao concluir um projeto, o core deve:
    - gerar nome de branch estável (`project/<slug>-<session-hint>`);
    - criar branch local se não existir (sem checkout automático);
    - incluir no resumo do projeto o branch reservado e próximo comando sugerido.
  - `/project` e `/kanban` devem delegar ao core (`ProjectRouter`) para:
    - iniciar/continuar wizard;
    - renderizar board por sessão com fallback para `TODO.md`.
  - canais devem manter responsabilidades de transporte:
    - extração de texto/anexos;
    - resolução de `session_id`;
    - envio da resposta.
- Critérios de aceite:
  1. saída final do wizard inclui referência ao branch do projeto;
  2. falha de Git não derruba o fluxo (mensagem amigável e continuação do plano);
  3. Telegram e Discord chamam o roteador core para `/project` e `/kanban`;
  4. testes cobrem criação/falha de branch e roteamento core-first.

### Higiene de Warnings no Ambiente de Teste (SPR-081)
- Objetivo:
  - remover warnings evitáveis que poluem `mix test` e mascaram regressões reais;
  - manter `mix compile` e a compilação de testes sem redefinições artificiais nem violações triviais de behaviour.
- Interfaces públicas afetadas:
  - `test/test_helper.exs`
  - `test/support/mocks.ex`
  - adapters de teste que implementam `Pincer.LLM.Provider`
- Regras v1:
  - `test/support` deve ser carregado uma única vez no ambiente `:test`;
  - adapters de teste que declaram `@behaviour Pincer.LLM.Provider` devem implementar todos os callbacks exigidos, ainda que via helper compartilhado;
  - testes de macros não devem induzir warnings do compilador por padrões obviamente inalcançáveis quando isso não faz parte do objetivo do teste.
- Critérios de aceite:
  1. recompilação forçada em `MIX_ENV=test` não emite warnings de redefinição de mocks/stubs;
  2. adapters de teste deixam de emitir warnings por callbacks obrigatórios ausentes;
  3. o teste de `assert_ok/1` continua cobrindo o erro sem emitir warning de tipagem trivial.

### Enforcement de `--warnings-as-errors` no DX (SPR-082)
- Objetivo:
  - transformar warnings de compilação em falha explícita por padrão no ciclo de desenvolvimento;
  - impedir regressão silenciosa da política via configuração do projeto.
- Interfaces públicas afetadas:
  - `mix.exs`
  - `test/mix/aliases_test.exs`
  - `README.md`
- Regras v1:
  - `mix compile` deve tratar warnings como erro via configuração do projeto;
  - aliases de DX (`qa`, `test.quick`, `sprint.check`) devem propagar `--warnings-as-errors` para testes;
  - a documentação de teste deve refletir o fluxo estrito.
- Critérios de aceite:
  1. `Mix.Project.config/0` expõe `elixirc_options` com `warnings_as_errors: true`;
  2. aliases de DX incluem `compile --warnings-as-errors` ou `test --warnings-as-errors` conforme aplicável;
  3. README deixa explícito o comando de teste estrito.

### Hygiene do Unit Systemd do Server (SPR-083)
- Objetivo:
  - evitar sinais duplicados de shutdown no restart do serviço;
  - garantir que o flag global do Mix `--no-compile` seja interpretado pelo Mix, não pelo task `pincer.server`.
- Interfaces públicas afetadas:
  - `infrastructure/systemd/pincer.service`
  - `test/mix/tasks/pincer_server_test.exs`
- Regras v1:
  - o unit template não deve declarar `ExecStop` explícito para reenviar `SIGTERM` ao `MAINPID`; o stop deve ficar a cargo do próprio systemd;
  - `ExecStart` deve chamar diretamente `mix pincer.server telegram`, sem flags espúrios depois do nome do task que acabem sendo tratados como canal.
- Critérios de aceite:
  1. o template não contém `ExecStop=/bin/kill -TERM $MAINPID`;
  2. o template contém `ExecStart=/usr/bin/env mix pincer.server telegram`;
  3. o teste de regressão do template cobre ambos os pontos.

### Roteamento de Agente Raiz por Usuário do Telegram + Blackboard Escopado (SPR-085)
- Objetivo:
  - permitir que múltiplos usuários conversem com o mesmo bot do Telegram, mas cada DM seja roteada para um agente raiz estável (`agent_id`) com bootstrap/persona/memória próprios;
  - eliminar bleed de coordenação interna entre agentes raiz ao escopar Blackboard e recovery por sessão raiz.
- Interfaces públicas afetadas:
  - `config.yaml`
  - `Pincer.Core.SessionScopePolicy`
  - `Pincer.Core.Session.Supervisor`
  - `Pincer.Core.Session.Server`
  - `Pincer.Core.AgentPaths`
  - `Pincer.Core.Orchestration.Blackboard`
  - `Pincer.Core.Orchestration.SubAgent`
  - `Pincer.Core.Project.Server`
  - `Pincer.Channels.Telegram`
- Regras v1:
  - `channels.telegram.agent_map` pode mapear IDs de DM do Telegram para um `agent_id` estável:
    - exemplo:
      - `"123": "annie"`
      - `"456": "lucie"`
  - em chat privado do Telegram:
    - se existir entrada em `agent_map`, `SessionScopePolicy.resolve/3` deve retornar esse `agent_id`;
    - se não existir entrada, o fallback continua sendo o comportamento atual (`telegram_<chat_id>` ou `telegram_main` conforme `dm_session_scope`).
  - em chats não privados, `agent_map` não altera o roteamento.
  - `Pincer.Core.Session.Supervisor.start_session/2` deve aceitar opções de inicialização da sessão.
  - sessões iniciadas a partir de `agent_map` devem usar scaffold/template local sem copiar persona legada da raiz do repo.
  - `AgentPaths.ensure_workspace!/2` deve permitir desabilitar fallback legado de persona/bootstrap ao criar agentes raiz explicitamente mapeados.
  - `Blackboard.post/4` e `Blackboard.fetch_new/2` devem aceitar um `scope` lógico:
    - root session usa `scope = session_id`;
    - sub-agentes e projetos publicam no mesmo `scope` da root session;
    - `Session.Server` consome somente mensagens do seu próprio `scope`.
  - mensagens antigas do journal sem `scope` não devem ser injetadas no histórico de sessões escopadas.
- Critérios de aceite:
  1. DM `123` pode ser roteada para `annie` e DM `456` para `lucie` usando o mesmo bot/token;
  2. workspaces canônicos ficam em `workspaces/annie/.pincer/` e `workspaces/lucie/.pincer/`;
  3. criação inicial de `annie`/`lucie` não copia `IDENTITY.md`, `SOUL.md`, `USER.md` ou `BOOTSTRAP.md` legados da raiz quando a sessão nasce via `agent_map`;
  4. Blackboard/recovery de `annie` não aparece no histórico de `lucie`, e vice-versa;
  5. fallback compatível permanece para DMs sem entrada em `agent_map`.

### CLI para Criar Agente Raiz Explícito (SPR-086)
- Objetivo:
  - expor um comando de CLI explícito para criar um agente raiz com workspace próprio em `workspaces/<agent_id>/.pincer/`;
  - tornar a criação do agente idempotente e segura, sem copiar persona legada compartilhada da raiz do repo.
- Interface pública:
  - `mix pincer.agent new <agent_id>`
  - `Mix.Tasks.Pincer.Agent.run/1`
- Regras v1:
  - o único subcomando inicial é `new`;
  - `agent_id` deve ser um identificador seguro para diretório (`[A-Za-z0-9_-]+`);
  - o comando cria ou garante a existência de:
    - `workspaces/<agent_id>/.pincer/BOOTSTRAP.md`
    - `workspaces/<agent_id>/.pincer/MEMORY.md`
    - `workspaces/<agent_id>/.pincer/HISTORY.md`
    - `workspaces/<agent_id>/.pincer/sessions/`
  - `IDENTITY.md`, `SOUL.md` e `USER.md` não devem ser copiados da raiz legada do repositório;
  - se `workspaces/.template/.pincer/` existir, `BOOTSTRAP.md`, `MEMORY.md` e `HISTORY.md` devem ser semeados a partir desse template;
  - reruns não podem sobrescrever arquivos já existentes no workspace do agente;
  - uso inválido deve falhar com mensagem explícita de uso.

### Pairing Direcionado para Agentes Explícitos (SPR-087)
- Objetivo:
  - permitir que o operador emita códigos de pairing genéricos ou direcionados a um `agent_id` explícito;
  - fazer com que `/pair <codigo>` em DM do Telegram vincule o remetente ao agente correto sem depender de `agent_map` estático;
  - preservar o fallback genérico criando um agente dedicado por DM quando o código não tiver alvo explícito.
- Interfaces públicas afetadas:
  - `mix pincer.agent pair [agent_id]`
  - `Pincer.Core.Pairing.issue_invite/2`
  - `Pincer.Core.Pairing.bound_agent_id/2`
  - `Pincer.Core.Pairing.bound_agent_session?/2`
  - `Pincer.Core.SessionScopePolicy.resolve/3`
  - fluxo `/pair` em `Pincer.Channels.Telegram`
- Regras v1:
  - `mix pincer.agent pair annie` deve:
    - validar `agent_id` com a mesma regra de `mix pincer.agent new`;
    - falhar se `workspaces/annie/.pincer/` não existir;
    - emitir um código out-of-band para o canal Telegram direcionado ao agente `annie`.
  - `mix pincer.agent pair` sem `agent_id` deve emitir um código genérico para o canal Telegram.
  - códigos emitidos por `issue_invite/2` não são pré-vinculados a `sender_id`; qualquer usuário que enviar `/pair <codigo>` em DM privada do Telegram pode consumi-los uma única vez.
  - ao consumir um código direcionado:
    - o `sender_id` fica marcado como `paired`;
    - `bound_agent_id(:telegram, sender_id)` deve retornar o `agent_id` explícito.
  - ao consumir um código genérico no Telegram:
    - o `sender_id` fica marcado como `paired`;
    - um novo `agent_id` hexadecimal opaco deve ser criado e vinculado ao remetente, independentemente de `dm_session_scope`.
  - `SessionScopePolicy.resolve/3` para DMs do Telegram deve consultar `agent_map` primeiro, depois `bound_agent_id/2`, e só então cair no fallback legado.
  - `approve_code/4` deve aceitar tanto códigos pendentes legados vinculados ao sender quanto invites out-of-band; um invite válido não pode ser rejeitado apenas porque existe pending legado para o mesmo sender.
  - sessões iniciadas a partir de binding dinâmico de pairing devem usar scaffold/template local sem copiar persona legada da raiz.
  - o binding `sender -> agent_id` deve persistir no store de pairing entre reinícios.
- Critérios de aceite:
  1. `mix pincer.agent pair annie` gera código para `annie` e falha com mensagem clara se `annie` não existir;
  2. `/pair <codigo_direcionado>` em DM privada do Telegram vincula o remetente a `annie`;
  3. `/pair <codigo_generico>` em DM privada do Telegram vincula o remetente a um novo agente raiz com `agent_id` hexadecimal opaco mesmo quando `dm_session_scope` está em `main`;
  4. `SessionScopePolicy.resolve/3` respeita `agent_map` estático antes do binding dinâmico e mantém fallback compatível;
  5. binding de pairing sobrevive à recriação das tabelas runtime.
- Critérios de aceite:
  1. `mix pincer.agent new annie` cria `workspaces/annie/.pincer/` com scaffold mínimo e sem persona herdada da raiz;
  2. rerodar `mix pincer.agent new annie` preserva `BOOTSTRAP.md`, `IDENTITY.md`, `SOUL.md` e `USER.md` já personalizados;
  3. `mix pincer.agent`, `mix pincer.agent new` e `mix pincer.agent new ../oops` falham com erro amigável;
  4. o task é classificado em `Pincer.Mix` e aparece documentado no `README.md`.

### Identidade Hexagonal de Agente e Binding Multi-Canal (SPR-088)
- Objetivo:
  - separar definitivamente identidade interna do agente, identidade externa do usuário e identidade da conversa;
  - permitir que múltiplos bindings externos apontem para o mesmo agente raiz sem fundir históricos de conversa;
  - parar de inferir workspace e blackboard a partir de `session_id`.
- Conceitos canônicos:
  - `agent_id`: identificador interno, opaco e imutável do agente raiz;
  - `display_name`: opcional e definido no bootstrap/persona; não participa do roteamento;
  - `principal_ref`: identidade externa normalizada, ex. `telegram:user:123`;
  - `conversation_ref`: identidade da conversa concreta, ex. `telegram:dm:123`;
  - `session_id`: identificador operacional da conversa no runtime e no storage de mensagens;
  - `root_agent_id`: agente raiz responsável por persona, workspace e escopo de blackboard.
- Interfaces públicas novas:
  - `Pincer.Core.AgentRegistry`
  - `Pincer.Core.Bindings`
  - `Pincer.Core.Session.Context`
  - `Pincer.Core.SessionResolver`
- Interfaces públicas afetadas:
  - `Pincer.Core.Session.Server`
  - `Pincer.Core.Session.Supervisor`
  - `Pincer.Core.Pairing`
  - `Pincer.Core.SessionScopePolicy`
  - canais Telegram, Discord e WhatsApp
  - `mix pincer.agent new [agent_id]`
- Regras v1:
  - `AgentRegistry.create_root_agent!/1` deve gerar `agent_id` hexadecimal opaco com 6 dígitos quando nenhum `agent_id` explícito for informado;
  - `mix pincer.agent new` sem argumentos deve criar um agente novo com esse `agent_id` opaco e imprimir o ID resultante;
  - `mix pincer.agent new <agent_id>` continua permitido para criação explícita/manual;
  - `Bindings.principal_ref/3` deve normalizar identidades externas no formato `<channel>:<kind>:<external_id>`;
  - `Bindings.resolve/1` deve devolver o `agent_id` atualmente vinculado ao `principal_ref`, com fallback compatível para o store legado de pairing;
  - `Bindings.bind/2` deve persistir o vínculo `principal_ref -> agent_id` usando o mecanismo de persistência do pairing;
  - `SessionScopePolicy.resolve/3` passa a resolver apenas `session_id` operacional da conversa, sem retornar `agent_id` explícito;
  - `SessionResolver.resolve/3` deve devolver um `%Pincer.Core.Session.Context{}` contendo ao menos:
    - `session_id`
    - `principal_ref`
    - `conversation_ref`
    - `root_agent_id`
    - `root_agent_source`
    - `workspace_path`
    - `blackboard_scope`
  - `root_agent_source` deve indicar pelo menos:
    - `:session_scope` para fallbacks legados;
    - `:static_mapping` para `agent_map`;
    - `:binding` para vínculos dinâmicos;
  - `Session.Server` deve:
    - persistir mensagens e estado conversacional por `session_id`;
    - carregar persona/bootstrap/workspace por `root_agent_id`;
    - usar `blackboard_scope = root_agent_id`;
    - manter logs de sessão em `.pincer/sessions/session_<session_id>.md` dentro do workspace do agente raiz;
  - canais devem iniciar sessões passando `root_agent_id`, `principal_ref` e `conversation_ref` para o core;
  - no Telegram/Discord/WhatsApp em DM:
    - `session_id` continua obedecendo `dm_session_scope`;
    - `root_agent_id` vem de `agent_map`, depois `Bindings`, depois fallback de `SessionScopePolicy`;
  - códigos genéricos de pairing não devem mais vincular o usuário a `telegram_<chat_id>`:
    - ao aprovar um código genérico, deve ser criado um novo agente raiz com `agent_id` hexadecimal opaco;
    - esse `agent_id` deve ser persistido no pairing e visível por `Bindings.resolve/1`.
- Critérios de aceite:
  1. um mesmo usuário pode apontar `telegram:user:123` e `discord:user:456` para o mesmo `agent_id`;
  2. as duas conversas mantêm `session_id` separados, mas compartilham persona/workspace/blackboard do mesmo agente raiz;
  3. `SessionScopePolicy.resolve/3` não retorna mais `agent_id` explícito mapeado ou pareado;
  4. `mix pincer.agent new` sem argumentos gera ID hexadecimal opaco com 6 dígitos;
  5. `/pair <codigo_generico>` cria um agente novo com ID hexadecimal opaco e workspace próprio;
  6. workspaces e bootstrap de agentes explícitos/dinâmicos não copiam persona legada da raiz;
  7. suíte verde com `mix test --warnings-as-errors`.

## Incremento 2026-03-10 (Tool Suite de Arquivos v1)

### Objetivo
- elevar a tool `file_system` de leitura passiva para uma suíte mínima útil de trabalho em código;
- adicionar `write`, `search` e `patch` sem abrir escapes fora do workspace;
- manter compatibilidade com chamadas legadas que chegam apenas com `path + content`.

### Interfaces/Public API
- `Pincer.Adapters.Tools.FileSystem.spec/0`
- `Pincer.Adapters.Tools.FileSystem.execute/2`

### Regras
- a tool `file_system` passa a suportar:
  - `list`
  - `read`
  - `write`
  - `search`
  - `patch`
- `write`:
  - exige `path` e `content`;
  - cria diretórios pais quando necessário;
  - sobrescreve o arquivo alvo;
  - falha ao apontar para diretório.
- `search`:
  - exige `query`;
  - aceita `path` de arquivo ou diretório;
  - quando `path` for diretório, faz busca recursiva em arquivos regulares;
  - não deve seguir symlinks;
  - retorna resultados com caminho relativo e número da linha.
- `patch`:
  - exige `path`, `old_text` e `new_text`;
  - opera por substituição textual exata;
  - falha quando `old_text` não existe;
  - falha quando houver múltiplas ocorrências e `replace_all` não estiver ativo.
- chamadas sem `action` devem inferir:
  - `write` quando houver `content`;
  - `patch` quando houver `old_text` e `new_text`;
  - `search` quando houver `query`;
  - `read` quando houver apenas `path`.
- todas as novas ações devem respeitar a mesma política de confinement do workspace usada em `read`.

### Critérios de aceite
1. Teste prova que `write` cria/atualiza arquivo dentro do workspace.
2. Teste prova que chamada legada com `path + content` funciona como `write`.
3. Teste prova que `search` encontra hits recursivos com `path:line`.
4. Teste prova que `patch` substitui ocorrência única e persiste o arquivo.
5. Teste prova que `patch` rejeita caso ambíguo sem `replace_all`.
6. Teste prova que `write/search/patch` continuam bloqueando caminhos fora do workspace.

## Incremento 2026-03-10 (Tool Suite de Arquivos v1.1)

### Objetivo
- completar a suite de arquivos com operacoes basicas de mutacao segura;
- permitir fluxos comuns sem recorrer ao shell para tudo;
- manter a regra de `trash > rm`.

### Interfaces/Public API
- `Pincer.Adapters.Tools.FileSystem.spec/0`
- `Pincer.Adapters.Tools.FileSystem.execute/2`

### Regras
- a tool `file_system` passa a suportar adicionalmente:
  - `append`
  - `mkdir`
  - `delete_to_trash`
- `append`:
  - exige `path` e `content`;
  - cria diretórios pais quando necessário;
  - cria o arquivo se ele ainda não existir;
  - falha ao apontar para diretório.
- `mkdir`:
  - exige `path`;
  - cria diretórios recursivamente;
  - falha quando o caminho já existir como arquivo.
- `delete_to_trash`:
  - move arquivo ou diretório para um diretório de lixo dentro do workspace;
  - não pode apagar o root do workspace;
  - não pode mover itens que já estejam no trash interno;
  - deve retornar o destino final para recuperação manual.

### Critérios de aceite
1. Teste prova que `append` preserva o conteúdo existente e acrescenta o novo.
2. Teste prova que `mkdir` cria diretórios recursivos.
3. Teste prova que `delete_to_trash` move um arquivo para o trash interno.
4. Teste prova que `delete_to_trash` rejeita tentar mover o root do workspace.

## Incremento 2026-03-10 (Tool Suite de Arquivos v1.2)

### Objetivo
- cobrir operações de movimentação e duplicação sem depender de shell;
- manter semântica segura dentro do workspace;
- evitar overwrite implícito.

### Interfaces/Public API
- `Pincer.Adapters.Tools.FileSystem.spec/0`
- `Pincer.Adapters.Tools.FileSystem.execute/2`

### Regras
- a tool `file_system` passa a suportar adicionalmente:
  - `copy`
  - `move`
- ambas exigem:
  - `path`
  - `destination`
- ambas:
  - falham se o destino já existir e `overwrite` não for `true`;
  - exigem que origem e destino permaneçam dentro do workspace;
  - criam diretórios pais do destino quando necessário.
- `copy`:
  - copia arquivo regular;
  - para diretórios, copia recursivamente.
- `move`:
  - move arquivo ou diretório;
  - não pode mover o root do workspace;
  - não pode mover um diretório para dentro de seu próprio descendente.

### Critérios de aceite
1. Teste prova que `copy` duplica um arquivo sem remover a origem.
2. Teste prova que `move` realoca um arquivo dentro do workspace.
3. Teste prova que `copy` rejeita sobrescrever destino sem `overwrite`.
4. Teste prova que `move` rejeita mover diretório para dentro dele mesmo.

## Incremento 2026-03-10 (Core Tool: Git Inspect)

### Objetivo
- adicionar uma tool nativa de inspeção Git para operações de leitura frequentes;
- reduzir dependência de shell para workflows comuns de código;
- manter tudo confinado ao workspace.

### Interfaces/Public API
- `Pincer.Adapters.Tools.GitInspect.spec/0`
- `Pincer.Adapters.Tools.GitInspect.execute/2`

### Regras
- a tool `git_inspect` suporta:
  - `status`
  - `diff`
  - `log`
  - `branches`
- parâmetros:
  - `action` obrigatório;
  - `repo_path` opcional, default `.` dentro do workspace;
  - `target_path` opcional para `diff`;
  - `limit` opcional para `log`, default `10`, max `50`.
- a tool:
  - deve validar `repo_path` e `target_path` com confinement de workspace;
  - deve falhar claramente quando o caminho não for um repositório Git;
  - deve usar apenas comandos Git de leitura.

### Critérios de aceite
1. Teste prova que `status` retorna branch e arquivo modificado.
2. Teste prova que `diff` com `target_path` retorna patch do arquivo pedido.
3. Teste prova que `log` respeita `limit`.
4. Teste prova que a tool rejeita `repo_path` fora do workspace.

## Incremento 2026-03-10 (Tool Suite de Arquivos v1.3)

### Objetivo
- melhorar a precisão de leitura e inspeção da tool de arquivos;
- reduzir contexto desperdiçado em leituras grandes;
- tornar a busca mais seletiva.

### Interfaces/Public API
- `Pincer.Adapters.Tools.FileSystem.spec/0`
- `Pincer.Adapters.Tools.FileSystem.execute/2`

### Regras
- a tool `file_system` passa a suportar adicionalmente:
  - `stat`
- `read`:
  - aceita `from_line` opcional;
  - aceita `line_count` opcional;
  - quando presentes, retorna apenas a faixa pedida.
- `search`:
  - aceita `extension` opcional;
  - aceita `case_sensitive` opcional;
  - `extension` filtra arquivos por extensão antes da leitura.
- `stat`:
  - exige `path`;
  - retorna ao menos tipo, tamanho, caminho relativo e `mtime`.

### Critérios de aceite
1. Teste prova que `stat` retorna metadados do arquivo.
2. Teste prova que `read` com faixa de linhas retorna apenas o trecho solicitado.
3. Teste prova que `search` com `extension` filtra os hits corretamente.

## Incremento 2026-03-10 (Tool Suite de Arquivos v1.4)

### Objetivo
- melhorar discovery de arquivos no workspace;
- permitir navegação recursiva controlada;
- tornar leitura de logs e arquivos longos mais prática.

### Interfaces/Public API
- `Pincer.Adapters.Tools.FileSystem.spec/0`
- `Pincer.Adapters.Tools.FileSystem.execute/2`

### Regras
- a tool `file_system` passa a suportar adicionalmente:
  - `find`
- `list`:
  - aceita `recursive` opcional;
  - quando `true`, retorna caminhos relativos aninhados.
- `read`:
  - aceita `tail_lines` opcional;
  - quando presente, retorna apenas as ultimas linhas pedidas;
  - `tail_lines` e `from_line/line_count` nao podem ser combinados.
- `find`:
  - exige `path`;
  - aceita `glob` opcional;
  - aceita `type` opcional com valores `file`, `directory` e `any`;
  - aceita `extension` opcional para filtrar apenas arquivos;
  - respeita `max_results`.

### Critérios de aceite
1. Teste prova que `list` recursivo retorna caminhos relativos aninhados.
2. Teste prova que `read` com `tail_lines` retorna apenas o final do arquivo.
3. Teste prova que `find` encontra arquivos por `glob` e `extension`.

## Incremento 2026-03-10 (Tool Suite de Arquivos v1.5)

### Objetivo
- tornar edicoes de arquivo mais robustas contra contexto stale;
- evitar patch textual baseado em reproducao de whitespace;
- permitir edicoes cirurgicas referenciando linhas verificaveis.

### Interfaces/Public API
- `Pincer.Adapters.Tools.FileSystem.spec/0`
- `Pincer.Adapters.Tools.FileSystem.execute/2`

### Regras
- `read`:
  - aceita `hashline` opcional;
  - quando `true`, cada linha retornada vem no formato `{line}#{hash}|{content}`.
- a tool `file_system` passa a suportar adicionalmente:
  - `anchored_edit`
- `anchored_edit`:
  - exige `path`;
  - exige `edits`;
  - suporta `replace`, `insert_after` e `insert_before`;
  - cada edit referencia uma linha via `anchor`;
  - `replace` pode aceitar `end_anchor` opcional para substituir uma faixa;
  - deve validar todos os anchors antes de escrever;
  - quando o arquivo mudou desde a leitura, deve falhar sem escrever e devolver contexto com anchors atualizados.
- o hash:
  - deve ser derivado do conteudo da linha;
  - deve permanecer estavel para a mesma linha lida;
  - pode ignorar variacoes de whitespace para reduzir fragilidade operacional.

### Critérios de aceite
1. Teste prova que `read` com `hashline` retorna linhas no formato `line#id|content`.
2. Teste prova que `anchored_edit` substitui uma linha usando apenas `anchor`.
3. Teste prova que `anchored_edit` consegue inserir linha apos um `anchor`.
4. Teste prova que `anchored_edit` rejeita anchor stale e nao grava o arquivo.

## Incremento 2026-03-10 (Tool Suite de Arquivos v1.6)

### Objetivo
- orientar o agente a preferir o caminho mais robusto de edicao;
- reduzir uso desnecessario de `patch` textual em codigo fonte.

### Interfaces/Public API
- `Pincer.Adapters.Tools.FileSystem.spec/0`

### Regras
- a spec exposta ao LLM deve deixar explicito que:
  - para editar codigo, o fluxo preferido e `read` com `hashline: true` seguido de `anchored_edit`;
  - `patch` fica reservado para substituicoes literais exatas e simples.
- a descricao de `hashline` deve indicar que ele prepara o caminho para `anchored_edit`.
- a descricao de `edits` deve mencionar `replace`, `insert_after` e `insert_before`.

### Critérios de aceite
1. Teste prova que a spec do `file_system` recomenda `hashline + anchored_edit` para edicao de codigo.
2. Teste prova que a spec do `file_system` descreve `patch` como fallback para substituicao literal exata.

## Incremento 2026-03-10 (Shell Invariants + Core Isolation)

### Objetivo
- garantir por regressao que o Core continue isolado da implementacao concreta de shell;
- tornar os testes unitarios do lado puro da shell mais rigorosos e invariantes;
- provar a integracao minima da `SafeShell` sem depender de MCP real.

### Interfaces/Public API
- `Pincer.Core.WorkspaceGuard.confine_path/2`
- `Pincer.Core.WorkspaceGuard.command_allowed?/2`
- `Pincer.Adapters.Tools.SafeShell.approved_command_allowed?/2`
- `Pincer.Adapters.Tools.SafeShell.execute/2`

### Regras
- o Core:
  - nao deve depender diretamente de `Pincer.Adapters.Tools`;
  - nao deve depender diretamente de `Pincer.Adapters.Tools.SafeShell`.
- `WorkspaceGuard.confine_path/2`:
  - rejeita path vazio;
  - rejeita null bytes;
  - permite desligar a rejeicao explicita de `..` apenas quando o caminho expandido continua confinado ao root;
  - continua rejeitando escapes por symlink.
- `WorkspaceGuard.command_allowed?/2`:
  - rejeita payload nao-binario;
  - rejeita comando fora da whitelist;
  - continua aceitando comandos dinamicos vindos de `CommandProfile` apenas quando o workspace detecta o stack correspondente.
- `SafeShell.execute/2`:
  - quando aceita um comando, deve repassar para `ToolRegistry` um `command` sanitizado;
  - com `restrict_to_workspace`, deve incluir `cwd`;
  - sem `restrict_to_workspace`, nao deve incluir `cwd`.

### Critérios de aceite
1. Teste estrutural prova que `lib/pincer/core/**` nao referencia `Pincer.Adapters.Tools`.
2. Testes de unidade validam invariantes de `WorkspaceGuard` para path vazio, null byte, `..` controlado e comandos invalidos.
3. Teste de integracao prova que `SafeShell.execute/2` envia `command` sanitizado e `cwd` quando restrito ao workspace.
4. Teste de integracao prova que `SafeShell.execute/2` nao envia `cwd` quando `restrict_to_workspace: false`.

## Incremento 2026-03-10 (Tool Contracts + Editor Fixtures Stress)

### Objetivo
- validar que a superficie de tools nativas exposta ao agente permanece coerente;
- validar editores de arquivo em cima de fixtures completas, nao so strings artificiais;
- submeter o `anchored_edit` a uma carga maior de edicoes verificaveis.

### Interfaces/Public API
- `Pincer.Adapters.NativeToolRegistry.list_tools/0`
- `Pincer.Adapters.Tools.FileSystem.execute/2`

### Regras
- toda tool nativa listada no registry deve expor spec bem-formada:
  - `name` string nao-vazia;
  - `description` string nao-vazia;
  - `parameters.type == "object"`;
  - `parameters.properties` map.
- o teste de fixtures do `file_system` deve:
  - operar sobre um workspace copiado de fixtures completas;
  - validar `read`, `find`, `search`, `stat` e os caminhos de edicao;
  - validar o resultado final dos arquivos editados.
- o teste de estresse do hash editor deve:
  - ler arquivo grande com `hashline: true`;
  - aplicar multiplas edicoes ancoradas em um unico passo;
  - provar que o resultado final preserva integridade estrutural;
  - provar que anchors stale continuam sendo rejeitados durante o fluxo.

### Critérios de aceite
1. Teste prova que todas as tools nativas expostas pelo registry possuem spec estrutural valida.
2. Teste com fixtures prova que `file_system` encontra, le e edita arquivos reais do workspace esperado.
3. Teste de estresse prova que `anchored_edit` aplica varias edicoes em arquivo grande sem corromper a estrutura.
4. Teste de estresse prova que um segundo lote com anchors stale e rejeitado sem gravar.

## Incremento 2026-03-10 (Fallback Tool Parser Alignment)

### Objetivo
- alinhar o parser heuristico de tools com a superficie real atual do agente;
- evitar nomes legados de tool no caminho de fallback;
- favorecer `file_system` e `anchored_edit` quando o payload parecer edicao de codigo.

### Interfaces/Public API
- `Pincer.LLM.ToolParser.parse/1`

### Regras
- no caminho heuristico/XML:
  - `command` deve inferir `safe_shell`, nao `run_command`;
  - `path` sozinho deve inferir `file_system`, nao `read_file`;
  - `path + anchor + content` deve ser normalizado para `file_system` com `action: anchored_edit`;
  - quando `op` estiver ausente nesse caso, assumir `replace`.
- o parser deve preservar `tool_calls` nativos existentes.

### Critérios de aceite
1. Teste prova que XML com `command` vira `safe_shell`.
2. Teste prova que XML com apenas `path` vira `file_system`.
3. Teste prova que XML com `path + anchor + content` vira `file_system` com `action: anchored_edit` e `edits`.

## Incremento 2026-03-11 (Telegram Sub-Agent UX v1)

### Objetivo
- transformar progresso de subagente em um painel editavel e legivel no Telegram;
- evitar spam de mensagens soltas de subagente no canal;
- mostrar reasoning visivel em bloco preformatado, nao em blockquote.

### Interfaces/Public API
- `Pincer.Core.SubAgentProgress.apply_event/2`
- `Pincer.Core.SubAgentProgress.render_dashboard/1`
- `Pincer.Core.Orchestration.SubAgent`
- `Pincer.Channels.Telegram.Session`
- `Pincer.Channels.Telegram.send_message/3`

### Regras
- `SubAgent` deve continuar emitindo status textual para compatibilidade, mas tambem publicar `{:subagent_progress, event}` no PubSub da sessao pai.
- `apply_event/2` deve atualizar um tracker deterministico por `agent_id`.
- `render_dashboard/1` deve gerar um checklist consolidado com:
  - `agent_id`;
  - `goal`;
  - estado de `Started`;
  - ultimo `tool` conhecido;
  - ultimo `runtime status` conhecido;
  - `Finished` ou `Failed`.
- `Telegram.Session` deve:
  - consumir `{:subagent_progress, event}`;
  - criar uma unica mensagem quando o primeiro evento chegar;
  - editar essa mesma mensagem quando o dashboard mudar;
  - ignorar `{:agent_status, text}` de subagente para evitar duplicacao.
- `Telegram.send_message/3` e `update_message/4`, com `skip_reasoning_strip: true`, devem renderizar `<thinking>`/`<thought>` dentro de `<pre>...</pre>`.

### Critérios de aceite
1. Teste de core prova que `apply_event/2` acumula goal/tool/status/resultado por subagente.
2. Teste de core prova que `render_dashboard/1` gera checklist consistente para running, finished e failed.
3. Teste de Telegram Session prova que um `subagent_progress` cria a mensagem inicial e eventos seguintes editam a mesma mensagem.
4. Teste de Telegram Session prova que `agent_status` de subagente nao gera mensagem duplicada.
5. Teste de Telegram prova que reasoning visivel e enviado em `<pre>...</pre>`.

## Incremento 2026-03-11 (Channel Actions v1)

### Objetivo
- expor envio de mensagens entre canais como tool nativa de primeira classe;
- permitir que o agente use o canal atual por default, sem precisar repetir alvo toda hora;
- permitir roteamento explicito para Telegram, Discord e WhatsApp.

### Interfaces/Public API
- `Pincer.Adapters.Tools.ChannelActions.spec/0`
- `Pincer.Adapters.Tools.ChannelActions.execute/2`

### Regras
- a tool deve se chamar `channel_actions`.
- `action` inicial suportada: `send_message`.
- o alvo pode ser resolvido de tres formas:
  - `recipient` explicito, junto com `channel`;
  - `target_session_id` explicito;
  - contexto atual da sessao (`session_id`), quando o envio for para o mesmo canal/conversa.
- `execute/2` deve:
  - ler `session_id` do contexto;
  - quando necessario, consultar `Session.Server.get_status/1` para inferir `principal_ref`/contexto atual;
  - rotear para o adapter correto de `Telegram`, `Discord` ou `WhatsApp`;
  - retornar erro claro para canal nao suportado ou alvo insuficiente.
- a spec exposta ao LLM deve deixar claro que:
  - omitir `channel`/`recipient` usa o contexto atual quando possivel;
  - `target_session_id` pode ser usado para falar com outra conversa do proprio Pincer.

### Critérios de aceite
1. Teste prova que `send_message` sem alvo explicito usa a conversa atual.
2. Teste prova que `send_message` com `channel + recipient` roteia para o adapter correto.
3. Teste prova que `send_message` com `target_session_id` resolve o recipient a partir do prefixo da sessao.
4. Teste prova que `channel_actions` aparece no registry nativo.
5. Teste prova que a tool retorna erro claro quando nao consegue resolver destino.

## Incremento 2026-03-13 (Status Message Policy v1)

### Objetivo
- puxar a semantica de upsert de mensagens de status para `Core`;
- reduzir duplicacao entre sessoes de Telegram e Discord;
- deixar os canais responsaveis apenas por `send/edit` e fallback de transporte.

### Interfaces/Public API
- `Pincer.Core.StatusMessagePolicy.initial_state/0`
- `Pincer.Core.StatusMessagePolicy.next_action/2`
- `Pincer.Core.StatusMessagePolicy.mark_sent/3`
- `Pincer.Core.StatusMessagePolicy.mark_edited/2`
- `Pincer.Channels.Telegram.Session`
- `Pincer.Channels.Discord.Session`

### Regras
- `StatusMessagePolicy` deve operar sobre um mapa com `status_message_id` e `status_message_text`.
- `next_action/2` deve:
  - retornar `:noop` quando o texto novo for `nil`, vazio ou igual ao ultimo texto entregue;
  - retornar `{:send, text}` quando ainda nao existir `status_message_id`;
  - retornar `{:edit, message_id, text}` quando a mensagem de status ja existir e o texto mudar.
- `mark_sent/3` deve persistir `status_message_id` e `status_message_text`.
- `mark_edited/2` deve atualizar apenas `status_message_text`, preservando `status_message_id`.
- `Telegram.Session` e `Discord.Session` devem usar essa politica para mensagens de status agregadas, mantendo o fallback de transporte atual quando `edit` falhar.

### Critérios de aceite
1. Teste de core prova `send`, `edit` e `noop` da politica.
2. Teste de core prova que `mark_sent/3` e `mark_edited/2` atualizam o estado corretamente.
3. Testes existentes de Telegram e Discord continuam verdes, sem regressao de upsert de status.

## Incremento 2026-03-13 (Core Stream Delivery Helper v1)

### Objetivo
- tirar das sessoes de canal a coreografia de `partial/final` com fallback `edit -> send`;
- manter `Core` como dono da semantica de preview/finalizacao;
- deixar Telegram e Discord apenas injetarem callbacks de transporte.

### Interfaces/Public API
- `Pincer.Core.StreamDelivery.handle_partial/5`
- `Pincer.Core.StreamDelivery.handle_final/3`
- `Pincer.Core.StreamingPolicy`
- `Pincer.Channels.Telegram.Session`
- `Pincer.Channels.Discord.Session`

### Regras
- `handle_partial/5` deve:
  - delegar acumulacao e decisao de preview para `StreamingPolicy`;
  - usar callback `send` quando ainda nao existir `message_id`;
  - usar callback `edit` quando existir `message_id`, com fallback para `send` se o edit falhar;
  - devolver o estado do canal atualizado com `StreamingPolicy.assign/2`.
- `handle_final/3` deve:
  - delegar decisao final para `StreamingPolicy.on_final/2`;
  - enviar mensagem final unica quando nao houver preview;
  - editar a preview existente quando houver `message_id`, com fallback para `send` se o edit falhar;
  - resetar o estado de streaming no retorno.
- O helper deve aceitar callbacks de transporte por keyword list:
  - `send: (text -> result)`
  - `edit: (message_id, text -> result)`

### Critérios de aceite
1. Teste de core prova que `partial` inicial cria preview via `send` e persiste `message_id`.
2. Teste de core prova que `partial` com `edit` falhando faz fallback para `send`.
3. Teste de core prova que `final` com preview existente edita in-place e reseta o estado.
4. Teste de core prova que `final` com `edit` falhando faz fallback para `send` e ainda reseta o estado.
5. Telegram e Discord continuam verdes usando o helper central.

## Incremento 2026-03-13 (Core Response Envelope Policy v1)

### Objetivo
- mover para `Core` a formacao do texto final visivel e das flags puras de delivery;
- separar calculo deterministico de efeito (`Session.Server.get_status/1`, `send_message`, `update_message`);
- reduzir responsabilidade de `Telegram.Session`.

### Interfaces/Public API
- `Pincer.Core.ResponseEnvelope.build/4`
- `Pincer.Core.ResponseEnvelope.delivery_options/2`
- `Pincer.Channels.Telegram.Session`

### Regras
- `build/4` deve receber:
  - `channel`
  - `text`
  - `usage`
  - `usage_display`
- `build/4` deve:
  - normalizar `nil` para string vazia;
  - anexar linha de usage somente quando o channel suportar e `usage_display` estiver habilitado;
  - retornar `""` quando nada precisar ser entregue.
- `delivery_options/2` deve ser pura e derivar flags de transporte a partir de:
  - `channel`
  - `%{reasoning_visible: boolean()}`
- em v1:
  - Telegram usa `<i>📊 ...</i>` para `tokens` e `full`;
  - Discord nao altera o texto final nem produz flags extras;
  - `reasoning_visible: true` em Telegram gera `[skip_reasoning_strip: true]`.

### Critérios de aceite
1. Teste de core prova montagem do texto final de Telegram com usage `tokens`.
2. Teste de core prova montagem do texto final de Telegram com usage `full`.
3. Teste de core prova que Discord nao anexa usage.
4. Teste de core prova flags de delivery para Telegram com reasoning visivel e oculto.
5. `Telegram.Session` passa a usar o modulo puro sem regressao nos testes existentes.

## Incremento 2026-03-13 (Core Status Delivery Helper v1)

### Objetivo
- extrair o upsert de mensagens de status para um helper unico de `Core`;
- remover duplicacao de fallback `edit -> send` em Telegram e Discord;
- manter `StatusMessagePolicy` como modulo de decisao pura e o helper como orquestrador de efeitos.

### Interfaces/Public API
- `Pincer.Core.StatusDelivery.deliver/3`
- `Pincer.Core.StatusMessagePolicy`
- `Pincer.Channels.Telegram.Session`
- `Pincer.Channels.Discord.Session`

### Regras
- `deliver/3` deve:
  - consultar `StatusMessagePolicy.next_action/2`;
  - chamar callback `send` quando a policy retornar `{:send, text}`;
  - chamar callback `edit` quando a policy retornar `{:edit, message_id, text}`;
  - em caso de falha no `edit`, fazer fallback para `send`;
  - atualizar o estado com `mark_sent/3` ou `mark_edited/2`;
  - preservar o estado quando a policy retornar `:noop` ou quando o transporte falhar.
- callbacks aceitos:
  - `send: (text -> result)`
  - `edit: (message_id, text -> result)`

### Critérios de aceite
1. Teste de core prova envio inicial e persistencia do `message_id`.
2. Teste de core prova `edit` bem-sucedido sem trocar `message_id`.
3. Teste de core prova fallback `edit -> send`.
4. Teste de core prova `noop` para texto repetido.
5. Telegram e Discord continuam verdes usando o helper.

## Incremento 2026-03-13 (Core Project Flow Delivery v1)

### Objetivo
- centralizar a reacao de canais a `ProjectRouter.on_agent_response/1` e `on_agent_error/1`;
- remover duplicacao de mensagem `"Project Runner: ..."` e de `process_input/2`;
- deixar os canais injetarem apenas o callback de envio.

### Interfaces/Public API
- `Pincer.Core.ProjectFlowDelivery.on_response/3`
- `Pincer.Core.ProjectFlowDelivery.on_error/3`
- `Pincer.Channels.Telegram.Session`
- `Pincer.Channels.Discord.Session`

### Regras
- `on_response/3` deve:
  - consultar `ProjectRouter.on_agent_response/1`;
  - enviar `"Project Runner: #{progress.status_message}"` quando houver progresso;
  - chamar `Session.Server.process_input/2` somente em `{:next, progress}`;
  - retornar `:ok` para qualquer caminho.
- `on_error/3` deve:
  - consultar `ProjectRouter.on_agent_error/1`;
  - enviar `"Project Runner: #{progress.status_message}"` em `{:retry, progress}` e `{:paused, progress}`;
  - chamar `Session.Server.process_input/2` somente em `{:retry, progress}`;
  - retornar `:ok` para qualquer caminho.
- os dois helpers devem aceitar dependencias injetaveis por keyword:
  - `router`
  - `session_server`
  - `send_message`

### Critérios de aceite
1. Teste de core prova que `on_response/3` envia mensagem e reexecuta prompt em `:next`.
2. Teste de core prova que `on_response/3` envia mensagem sem reexecucao em `:completed`.
3. Teste de core prova que `on_error/3` envia mensagem e reexecuta prompt em `:retry`.
4. Teste de core prova que `on_error/3` envia mensagem sem reexecucao em `:paused`.
5. Telegram e Discord continuam verdes usando o helper.

## Incremento 2026-03-13 (Top 10 Error Routing v1)

### Objetivo
- tratar individualmente os erros operacionais mais comuns;
- transformar payloads de erro de provider em classes roteaveis;
- alinhar `ErrorClass` e `ErrorUX` para sugerir a via certa de resolucao.

### Interfaces/Public API
- `Pincer.Core.ErrorClass.classify/1`
- `Pincer.Core.ErrorUX.friendly/2`
- `Pincer.LLM.Providers.OpenAICompat.handle_response/1`

### Top 10 classes alvo
- `:missing_credentials`
- `:auth_cooling_down`
- `:tool_calling_unsupported`
- `:context_overflow`
- `:quota_exhausted`
- `:http_429`
- `:provider_payload`
- `:provider_non_json`
- `:provider_empty`
- `:transport_timeout`

### Regras
- `OpenAICompat.handle_response/1` deve converter `%{"error" => ...}` em `{:provider_error, code, message}`.
- `ErrorClass.classify/1` deve:
  - reconhecer `provider_error`, credenciais ausentes, cooldown de perfil, quota e erros de provider;
  - distinguir quota esgotada de rate limit generico;
  - continuar classificando transporte, DB e stream payload.
- `ErrorUX.friendly/2` deve gerar orientacao especifica por classe:
  - configurar credencial;
  - aguardar cooldown;
  - trocar modelo/provider;
  - usar `/reset`;
  - revisar endpoint;
  - aguardar e repetir.

### Critérios de aceite
1. Teste de provider prova que `%{"error" => ...}` vira `{:provider_error, code, message}`.
2. Teste de core prova classificacao individual das classes novas.
3. Teste de UX prova mensagens distintas para credenciais, cooldown, quota e payload de provider.

## Incremento 2026-03-13 (Error Actions By Class v1)

### Objetivo
- transformar parte da classificacao de erro em decisao operacional;
- evitar ruido de failover para erros claramente terminais;
- manter retry/failover apenas para classes transientes.

### Interfaces/Public API
- `Pincer.Core.RetryPolicy.fail_fast?/1`
- `Pincer.LLM.Client`

### Regras
- `fail_fast?/1` deve retornar `true` para classes terminais sem beneficio de retry/failover:
  - `:missing_credentials`
  - `:auth_cooling_down`
  - `:tool_calling_unsupported`
  - `:context_overflow`
  - `:provider_payload`
  - `:provider_non_json`
  - `:provider_empty`
  - `:http_401`
  - `:http_403`
  - `:http_404`
- `LLM.Client` deve:
  - interromper o fluxo terminal imediatamente quando `fail_fast?/1` for `true`;
  - nao emitir status de failover nesses casos;
  - manter retries/backoff para classes transientes.

### Critérios de aceite
1. Teste de core prova `fail_fast?/1` para classes terminais e negativas para classes transientes.
2. Teste de client prova que `provider_error` nao gera retry adicional.
3. Teste de client prova que `provider_error` nao emite status de failover.
