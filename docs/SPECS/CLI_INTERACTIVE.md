# CLI Interativo: Especificações (`pincer.chat`)

## 🎯 Objetivo
Um terminal interativo em linha de comando que permite conversar com o Pincer diretamente (`mix pincer.chat`), com histórico persistente e suporte completo ao ciclo de Assistente/Orquestrador.

---

## 🏗️ UX & Comandos

### Prompt
O usuário deve ser recebido com um prompt claro e feedback visual:

```bash
[CLI] Conectado ao Pincer (Sessão: cli_user)
Use /quit para sair, /clear para limpar.
--------------------------------------------------
[Manel]: _
```

### Comandos Reservados
O CLI deve interceptar as seguintes strings antes de enviá-las ao Session.Server:

- `/quit` ou `/q`: Encerra o processo do CLI (System.halt).
- `/clear`: Limpa a tela do terminal (IO.puts ANSI.clear).
- `/status`: Exibe o estado atual da Sessão (Idle/Working).

---

## 🔌 Protocolo de Comunicação

O módulo `Pincer.CLI` atuará como um **Client Process** para o `Pincer.Session.Server`.

1.  **Envio**: O CLI lê uma linha (`IO.gets`) e chama `Session.Server.process_input(session_id, input)`.
2.  **Identidade**: O `sender_pid` na chamada deve ser o próprio processo do CLI (`self()`).
3.  **Recepção (Loop de Mensagens)**:
    - O CLI deve entrar em um `receive` loop para aguardar respostas assíncronas do Assistente ou Orquestrador.
    - Mensagens esperadas:
        - `{:assistant_reply_finished, text}` -> Imprime: `[Pincer]: text`
        - `{:sme_status, role, status}` -> Imprime: `[STATUS]: role: status` (cor cinza)
        - `{:executor_finished, _, response}` -> Imprime: `[Concluído]: response` (cor verde)

---

## 🧪 Estratégia de Testes (TDD)

Como testar IO interativo é difícil, a lógica deve ser desacoplada em:

1.  `Pincer.CLI.start_link/1`: Inicia o processo loop.
2.  `Pincer.CLI.handle_input/2`: Pura. Recebe string -> Retorna ação (`:quit`, `:send`, `:clear`).
3.  **Mocking**: Para testes de integração, usaremos um `FakeSession` que responde mensagens ao processo de teste.
