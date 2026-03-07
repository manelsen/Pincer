# Pincer KANBAN & Roadmap (Master Plan)

## 🎯 Visão Geral
Um motor Elixir/OTP que combina a versatilidade do **NanoBot**, a orquestração de SMEs do **Swarm** e a soberania de dados local (Nx/LanceDB).

---

## 🏗️ ARQUITETURA & CORE

### [x] Orquestração SME (Inspirado no Swarm)
- [x] Implementar papéis de Agentes: **Architect**, **Coder**, **Reviewer**.
- [x] Ciclo de Vida: **Planning -> Execution -> QA**.
- [x] Context Injection entre agentes para manter a "conversa" técnica alinhada.

### [ ] Memória Vetorial & GraphRAG (Alta Performance)
- [x] **Janela Deslizante no "Sweet Spot":** Implementado cap em 25% da janela real (limitada via config do adapter) + preservação da "Injeção Fixa" inicial, resolvendo o *"Lost in the Middle"*.
- [x] Geração de Embeddings Local (Nx/Bumblebee).
- [x] Persistência em SQLite (Stopgap) e Relacionamentos via Grafo (`Pincer.Storage.Graph`).
- [x] **Migração para LanceDB** (Integração via Rustler/NIF) para busca vetorial escalável.
- [x] **Extração de Esqueleto de Código (Code Skeleton / Estilo th0th):**
  - Módulo que reduz tokens em ~98% ao extirpar a implementação/blocos `{}` e comentários, preservando apenas assinaturas (`def`, `import`, `class`).
  - Fornece o "Mapa do Território" ultra-barato para o LLM rotear sua busca profunda.
- [ ] **Sincronização Híbrida de Conhecimento (GraphRAG Sync)**
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

### [ ] MCP Host Universal (Nano-Inspirado)
- [x] Suporte a MCP via STDIO (Handshake corrigido).
- [ ] Suporte a MCP via HTTP/SSE.
- [ ] Carregamento dinâmico de `config.json` (padrão Cursor/Claude Desktop).

---

## ✨ CANAIS & INTERFACE (GATEWAYS)

### [x] Abstração Multi-canal
- [x] Telegram (Telegex).
- [x] **CLI Interativo** (`mix pincer.chat` com histórico persistente).
- [x] Webhook Universal para integração com outras ferramentas.

### [x] UX & Streaming
- [x] **Progress Streaming**: Enviar partes da resposta conforme o LLM gera (via Telegex edit_message). Implementado em Telegram e Discord.
- [ ] Notificações inteligentes de progresso do Sub-agente.

---

## 🛠️ FUNCIONALIDADES AVANÇADAS

### [x] Voz & Multimodal
- [x] Transcrição de voz automática no Telegram (Whisper via Groq API)
- [x] Processamento de imagens/logs enviados como arquivos (Inlining + Previews para logs grandes)

### [ ] Segurança & Proatividade
- [x] `restrict_to_workspace`: Sandbox para comandos shell e leitura de arquivos. Implementado via `WorkspaceGuard`.
- [ ] **Heartbeat Avançado**: Agentes que monitoram o GitHub em busca de mudanças e tomam a iniciativa.

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

Status atual: suíte completa verde (`541 testes + 2 doctests`, `0` falhas).
