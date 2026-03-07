# Pincer KANBAN & Roadmap (Master Plan)

## 🎯 Visão Geral
Um motor Elixir/OTP que combina a versatilidade do **NanoBot**, a orquestração de SMEs do **Swarm** e a soberania de dados local (Nx/LanceDB).

---

## 🏗️ ARQUITETURA & CORE

### [x] Orquestração SME (Inspirado no Swarm)
- [x] Implementar papéis de Agentes: **Architect**, **Coder**, **Reviewer**.
- [x] Ciclo de Vida: **Planning -> Execution -> QA**.
- [x] Context Injection entre agentes para manter a "conversa" técnica alinhada.

- [x] **Memória Vetorial & GraphRAG (Alta Performance)**
  - [x] **Janela Deslizante no "Sweet Spot":** Implementado cap em 25% da janela real (limitada via config do adapter) + preservação da "Injeção Fixa" inicial, resolvendo o *"Lost in the Middle"*.
  - [x] Geração de Embeddings Local (Nx/Bumblebee).
  - [x] Persistência em SQLite (Stopgap) e Relacionamentos via Grafo (`Pincer.Storage.Graph`).
  - [x] **Busca Vetorial Híbrida (SQLite Stopgap):** Implementado motor de busca vetorial nativo em Elixir (Similaridade de Cosseno) sobre SQLite, servindo como alternativa resiliente ao LanceDB em ambientes sem Rust/Cargo.

- [x] **Extração de Esqueleto de Código (Code Skeleton / Estilo th0th):**
  - Módulo que reduz tokens em ~98% ao extirpar a implementação/blocos `{}` e comentários, preservando apenas assinaturas (`def`, `import`, `class`).
  - Fornece o "Mapa do Território" ultra-barato para o LLM rotear sua busca profunda.
- [x] **Sincronização Híbrida de Conhecimento (GraphRAG Sync)**
  - [x] **Sincronização Local (Git/Watcher):** Hooks automáticos para re-indexar vetores após edições feitas pelo Pincer ou via commits (`git diff`). Implementado via SQLite Vector Stopgap.
  - [x] **RAG Dinâmico Externo via MCP (APIs e Linguagens):** 
    - Como lidar com tecnologias fast-moving (Gleam, Go 1.26, Odin)?
    - Ao detectar erro de compilação ou conhecimento obsoleto, o agente invoca o **MCP do GitHub** para extrair as *Release Notes* ou docs do repositório oficial (`github_search_code`).
    - Esse "texto limpo" é vetorizado na hora via API (ex: `openrouter/baai/bge-m3` por ~$0.01/1M tokens) e ingerido na coleção `external_docs` do LanceDB. Implementado via `ExternalKnowledge` tool.
  - [x] **Retroalimentação em Grafo (Experiência Dedutiva):**
    - Após o RAG resolver o problema, o agente consolida o aprendizado na **Memória em Grafos**: `[Bug] --(resolvido_em)--> [Módulo/Versão]`.
    - No próximo encontro com o mesmo erro (mesmo em outros projetos), o agente consulta o Grafo primeiro (fatos causais) antes de recorrer à busca vetorial cega ou ao GitHub, garantindo "memória de sênior". Implementado via `capture_tool_error_to_graph` e `Learning` tool.

### [x] Motor de Auto-Melhoria Contínua (Self-Improving Agent)
- [x] **Captura de Erros Autônoma (Error Nodes):** Interceptar falhas consecutivas de ferramentas (ex: `shell_server`, erros de sintaxe ou "tool_execution_failed") no `Pincer.Core.Executor` e salvar automaticamente como "Nós de Erro" estruturados (Metadata, Causa, Fix) na Memória de Grafos, sem depender da vontade do LLM.
- [x] **Promoção e Injeção Fixa (The Learning Loop):** 
  - Ao iniciar uma sessão em um repositório, o Pincer consulta o Grafo pelas "Lições Aprendidas" ou erros frequentes associados aos arquivos do contexto atual.
  - Injetar um sumário dessas lições diretamente no System Prompt (A "Injeção Fixa" do Sweet Spot).
- [x] **Comando Manual de Correção (`/learn` ou Rituais de Correção):** Quando o usuário corrigir o agente ("Não, o certo é X"), o agente deve acionar uma ferramenta que classifica o feedback (`knowledge_gap`, `best_practice`) e escreve no GraphMemory, linkando a "Aresta" a arquivos ou ferramentas.

### [x] MCP Host Universal (Nano-Inspirado)
- [x] Suporte a MCP via STDIO (Handshake corrigido).
- [x] Suporte a MCP via HTTP/SSE. Implementado no `HTTP` transport.
- [x] Carregamento dinâmico de `config.json` (padrão Cursor/Claude Desktop). Implementado no `ConfigLoader`.

---

## ✨ CANAIS & INTERFACE (GATEWAYS)

### [x] Abstração Multi-canal
- [x] Telegram (Telegex).
- [x] **CLI Interativo** (`mix pincer.chat` com histórico persistente).
- [x] Webhook Universal para integração com outras ferramentas.

### [x] UX & Streaming
- [x] **Progress Streaming**: Enviar partes da resposta conforme o LLM gera (via Telegex edit_message). Implementado em Telegram e Discord.
- [x] **Notificações inteligentes de progresso do Sub-agente**: Sub-agentes agora notificam a sessão pai via PubSub em tempo real (Push-based).

---

## 🛠️ FUNCIONALIDADES AVANÇADAS

### [x] Voz & Multimodal
- [x] Transcrição de voz automática no Telegram (Whisper via Groq API)
- [x] Processamento de imagens/logs enviados como arquivos (Inlining + Previews para logs grandes)

### [x] Segurança & Proatividade
- [x] `restrict_to_workspace`: Sandbox para comandos shell e leitura de arquivos. Implementado via `WorkspaceGuard`.
- [x] **Heartbeat Avançado**: Agentes que monitoram o GitHub em busca de mudanças e tomam a iniciativa. Implementado via `GitHubWatcher`.

---

## ✅ CONCLUÍDO
- [x] Arquitetura Master/Worker Assíncrona.
- [x] Resiliência de Rede (Retries no Client).
- [x] Identidade, Alma e Perfil de Usuário.
- [x] Integração API REST GitHub (Listagem Real).
- [x] Migração para Telegex (Modern Bot Framework).

---

## 🚨 Remediação de Falhas (2026-03-02)

Ordem de execução por risco (produção + segurança + quebra de contrato):

1. [x] **P0 Segurança**: fechar escape por symlink/path traversal no `WorkspaceGuard.confine_path/2`.
2. [x] **P0 Contrato de Porta**: alinhar `Pincer.Ports.LLM` com `stream_completion/2`.
3. [x] **P0 API Pública**: restaurar facade compatível de `ProjectOrchestrator` (`start/2`, `continue/2`, `reset/1`, `reset_all/0`, `kickoff/1`).
4. [x] **P1 Robustez de Execução**: corrigir ciclo de vida de worker no `Project.Server` (processo não-linkado + `terminate/2`) e respeitar `max_retries`.
5. [x] **P1 Streaming/Hot Swap**: propagar `{:agent_stream_token, ...}` para PubSub e encaminhar `{:model_changed, ...}` ao worker ativo.
6. [x] **P1 Orquestração**: tornar Blackboard determinístico em testes (fetch sem limite por padrão + `reset/0` + recuperação do journal após remoção do arquivo).
7. [x] **P2 Compatibilidade**: restaurar `Pincer.hello/0` para manter o smoke test padrão verde.
8. [x] **P2 Isolamento de Testes**: estabilizar suites que alteram config global de LLM (`planner` e `multimodal`).
9. [x] **P3 Arquitetura**: revisar startup supervisionado do Discord Consumer.
10. [x] **P3 Performance/Manutenção**: reduzir `acc ++ ...` em `Enum.reduce`.

Status atual: suíte completa verde (`515 testes + 2 doctests`, `0` falhas).

---

## 🚧 Isolamento de Agentes por Usuário no Mesmo Bot

Objetivo: permitir que usuários diferentes conversem com o mesmo bot do Telegram, mas sejam roteados para agentes raiz distintos, com bootstrap, identidade, memória, logs e coordenação interna sem bleed entre agentes.

- [x] Especificar em `SPECS.md` o contrato de roteamento `telegram user/chat id -> root agent id`, incluindo fallback quando não houver mapeamento.
- [x] Especificar em `SPECS.md` a garantia de isolamento esperada para identidade, bootstrap, memória, logs, sub-agentes e Blackboard.
- [x] Definir o shape de configuração em `config.yaml` para mapeamento estável de usuário do Telegram para agente raiz.
- [x] Implementar parser/normalizador da configuração de mapeamento de agentes no canal Telegram.
- [x] Implementar resolvedor de `agent_id` raiz para eventos privados do Telegram com fallback compatível ao comportamento atual.
- [x] Fazer o canal Telegram iniciar a sessão com `session_id` de conversa, mas carregar workspace/blackboard pelo `root_agent_id` resolvido.
- [x] Garantir que o workspace canônico do agente mapeado seja `workspaces/<agent_id>/.pincer/`.
- [x] Remover seed de persona a partir de arquivos legados compartilhados da raiz para agentes raiz provisionados por mapeamento explícito.
- [x] Garantir que um agente novo mapeado comece apenas com scaffold/template controlado e bootstrap local.
- [x] Particionar o Blackboard por agente raiz ou namespace de sessão para impedir que updates globais de um agente entrem no prompt de outro.
- [x] Particionar o journal do Blackboard de forma compatível com a nova chave de isolamento.
- [x] Propagar o namespace de isolamento do agente raiz para sub-agentes, projetos e recovery.
- [x] Garantir que consolidação do Archivist leia e escreva apenas dentro do workspace do agente raiz correto.
- [x] Adicionar teste de roteamento Telegram provando `123 -> annie` e `456 -> lucie`.
- [ ] Adicionar teste de bootstrap provando que Annie e Lucie podem nascer com personas distintas no mesmo bot.
- [x] Adicionar teste de não-vazamento provando que `IDENTITY/SOUL/USER` de um agente não aparecem no prompt do outro.
- [x] Adicionar teste de não-vazamento provando que mensagens do Blackboard de um agente não entram no histórico do outro.
- [x] Adicionar teste de compatibilidade garantindo fallback para `telegram_<chat_id>` quando não houver `agent_map`.
- [x] Documentar a configuração com exemplo real de casal/usuários distintos no `README.md`.
- [x] Documentar a estratégia de migração para sessões existentes baseadas em `telegram_<chat_id>`.

## ✅ CLI de Agente Raiz Explícito

- [x] Especificar `mix pincer.agent new <agent_id>` em `SPECS.md`.
- [x] Implementar task para criar `workspaces/<agent_id>/.pincer/` com scaffold idempotente.
- [x] Garantir que a criação explícita não copie persona legada da raiz do repositório.
- [x] Documentar o novo task no `README.md`.

## ✅ Pairing Direcionado por Agente

- [x] Especificar em `SPECS.md` o contrato de `mix pincer.agent pair [agent_id]`.
- [x] Estender `Pincer.Core.Pairing` para emitir códigos out-of-band genéricos e direcionados.
- [x] Persistir `sender -> agent_id` no store de pairing.
- [x] Fazer o `/pair` do Telegram aceitar invites direcionados e genéricos.
- [x] Fazer DMs pareadas genericamente criarem um novo `agent_id` opaco e vincularem o `principal_ref` ao agente.
- [x] Fazer o roteamento de sessão do Telegram consultar binding dinâmico após `agent_map`.
- [x] Garantir que sessões iniciadas por binding dinâmico não copiem persona legada da raiz.
- [x] Expor `mix pincer.agent pair [agent_id]` no CLI.
- [x] Cobrir o fluxo com testes de core, task e roteamento.
- [x] Documentar o fluxo no `README.md`.

## ✅ Identidade Hexagonal de Agente

- [x] Separar `agent_id`, `principal_ref`, `conversation_ref` e `session_id` no core.
- [x] Introduzir `AgentRegistry`, `Bindings`, `Session.Context` e `SessionResolver`.
- [x] Fazer `SessionScopePolicy` resolver apenas o `session_id` operacional da conversa.
- [x] Fazer `Session.Server` carregar persona/workspace/blackboard por `root_agent_id`.
- [x] Fazer Telegram, Discord e WhatsApp iniciarem sessões com contexto completo.
- [x] Fazer `mix pincer.agent new` sem argumentos gerar `agent_id` hexadecimal opaco.
- [x] Fazer pairing genérico criar agentes opacos em vez de `telegram_<chat_id>`.
