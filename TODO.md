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
