# Pincer KANBAN & Roadmap (Master Plan)

## 🎯 Visão Geral
Um motor Elixir/OTP que combina a versatilidade do **NanoBot**, a orquestração de SMEs do **Swarm** e a soberania de dados local (Nx/LanceDB).

---

## 🏗️ ARQUITETURA & CORE

### [x] Orquestração SME (Inspirado no Swarm)
- [x] Implementar papéis de Agentes: **Architect**, **Coder**, **Reviewer**.
- [x] Ciclo de Vida: **Planning -> Execution -> QA**.
- [x] Context Injection entre agentes para manter a "conversa" técnica alinhada.

### [x] Memória Vetorial de Alta Performance
- [x] Geração de Embeddings Local (Nx/Bumblebee).
- [x] Persistência em SQLite (Stopgap).
- [x] **Migração para LanceDB** (Integração via Rustler/NIF) para busca vetorial escalável.

### [ ] MCP Host Universal (Nano-Inspirado)
- [x] Suporte a MCP via STDIO (Handshake corrigido).
- [ ] Suporte a MCP via HTTP/SSE.
- [ ] Carregamento dinâmico de `config.json` (padrão Cursor/Claude Desktop).

---

## ✨ CANAIS & INTERFACE (GATEWAYS)

### [ ] Abstração Multi-canal
- [x] Telegram (Telegex).
- [ ] **CLI Interativo** (`mix pincer.chat` com histórico persistente).
- [ ] Webhook Universal para integração com outras ferramentas.

### [ ] UX & Streaming
- [ ] **Progress Streaming**: Enviar partes da resposta conforme o LLM gera (via Telegex edit_message).
- [ ] Notificações inteligentes de progresso do Sub-agente.

---

## 🛠️ FUNCIONALIDADES AVANÇADAS

### [ ] Voz & Multimodal
- [ ] Transcrição de voz automática no Telegram (Whisper via Bumblebee local).
- [ ] Processamento de imagens/logs enviados como arquivos.

### [ ] Segurança & Proatividade
- [ ] `restrict_to_workspace`: Sandbox para comandos shell e leitura de arquivos.
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
