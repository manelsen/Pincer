# ROADMAP — Pincer

> Cada Epic é um grande implemento. Cada Story é uma fatia entregável. Cada Task é um
> arquivo ou função concreta, tão pequena que um modelo mais fraco consegue executar
> sem contexto extra.
>
> **Convenção de prioridade:** 🔴 Alta · 🟡 Média · 🟢 Baixa
> **Convenção de tamanho de task:** XS < 30 min · S < 2 h · M < 1 dia

---

## EPIC-01 🔴 — Inline Buttons Telegram paginados para `/models`

**Motivação:** O menu `/models` atual lista todos os modelos em botões sem paginação.
Com muitos modelos por provider, os botões excedem o limite do Telegram e a UX fica
ruim no mobile. O OpenClaw tem paginação de 8 modelos/página com ◀ Prev / Next ▶
e marcação do modelo atual com `✓`.

**Objetivo:** substituir a lógica de `build_model_buttons/2` em
`Pincer.Channels.Telegram.UpdatesProvider` por um teclado paginado idêntico ao
`model-buttons.ts` do OpenClaw, usando o `ChannelInteractionPolicy` já existente.

---

### STORY-01.1 — Módulo de paginação de botões de modelo

#### TASK-01.1.1 XS
**Arquivo:** `lib/pincer/core/ux/model_keyboard.ex` (novo)
**O que fazer:** Criar o módulo com `@moduledoc` e definir as constantes:
```elixir
defmodule Pincer.Core.UX.ModelKeyboard do
  @page_size 8
  @max_callback_bytes 64
end
```
Não adicionar mais nada além do módulo vazio com as constantes.

---

#### TASK-01.1.2 XS
**Arquivo:** `lib/pincer/core/ux/model_keyboard.ex`
**O que fazer:** Adicionar a função `page_size/0` que retorna `@page_size`.
```elixir
@spec page_size() :: pos_integer()
def page_size, do: @page_size
```
Adicionar `@doc "Returns the number of models displayed per page."` antes da função.

---

#### TASK-01.1.3 S
**Arquivo:** `lib/pincer/core/ux/model_keyboard.ex`
**O que fazer:** Implementar `paginate/2` que recebe uma lista de strings e um número
de página (1-indexed) e retorna `{page_items, total_pages}`:
```elixir
@spec paginate([String.t()], pos_integer()) :: {[String.t()], pos_integer()}
def paginate(items, page) when is_list(items) and is_integer(page) and page >= 1 do
  total_pages = max(1, ceil(length(items) / @page_size))
  page = min(page, total_pages)
  offset = (page - 1) * @page_size
  page_items = Enum.slice(items, offset, @page_size)
  {page_items, total_pages}
end
```

---

#### TASK-01.1.4 S
**Arquivo:** `lib/pincer/core/ux/model_keyboard.ex`
**O que fazer:** Implementar `build_model_row/3` que recebe `provider_id :: String.t()`,
`model :: String.t()`, `current_model :: String.t() | nil` e retorna um botão inline:
```elixir
@spec build_model_row(String.t(), String.t(), String.t() | nil) :: map() | nil
def build_model_row(provider_id, model, current_model) do
  case ChannelInteractionPolicy.model_selector_id(:telegram, provider_id, model) do
    {:ok, callback_data} ->
      is_current = model == current_model
      label = if is_current, do: "#{model} ✓", else: model
      %{text: label, callback_data: callback_data}
    {:error, _} -> nil
  end
end
```
Adicionar `alias Pincer.Core.ChannelInteractionPolicy` no topo do módulo.

---

#### TASK-01.1.5 S
**Arquivo:** `lib/pincer/core/ux/model_keyboard.ex`
**O que fazer:** Implementar `build_pagination_row/3` que recebe `provider_id`,
`current_page`, `total_pages` e retorna uma lista de botões de paginação (pode ser
lista vazia se total_pages == 1):
```elixir
@spec build_pagination_row(String.t(), pos_integer(), pos_integer()) :: [map()]
def build_pagination_row(_provider_id, _current_page, 1), do: []
def build_pagination_row(provider_id, current_page, total_pages) do
  prev_btn = if current_page > 1 do
    [%{text: "◀ Prev",
       callback_data: "page:#{provider_id}:#{current_page - 1}"}]
  else
    []
  end
  counter = [%{text: "#{current_page}/#{total_pages}",
               callback_data: "noop"}]
  next_btn = if current_page < total_pages do
    [%{text: "Next ▶",
       callback_data: "page:#{provider_id}:#{current_page + 1}"}]
  else
    []
  end
  prev_btn ++ counter ++ next_btn
end
```

---

#### TASK-01.1.6 S
**Arquivo:** `lib/pincer/core/ux/model_keyboard.ex`
**O que fazer:** Implementar `build_keyboard/4` que compõe o teclado completo de
uma página de modelos. Recebe `provider_id`, `models` (lista completa), `page`,
`current_model`. Retorna `[[map()]]` (lista de linhas):
```elixir
@spec build_keyboard(String.t(), [String.t()], pos_integer(), String.t() | nil) :: [[map()]]
def build_keyboard(provider_id, models, page, current_model) do
  {page_models, total_pages} = paginate(models, page)
  model_rows =
    page_models
    |> Enum.map(&build_model_row(provider_id, &1, current_model))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&[&1])
  pagination_row = build_pagination_row(provider_id, page, total_pages)
  back_row = case ChannelInteractionPolicy.back_to_providers_id(:telegram) do
    {:ok, cb} -> [[%{text: "⬅️ Voltar", callback_data: cb}]]
    _ -> []
  end
  rows = if pagination_row == [], do: model_rows, else: model_rows ++ [pagination_row]
  rows ++ back_row
end
```

---

#### TASK-01.1.7 S
**Arquivo:** `test/pincer/core/ux/model_keyboard_test.exs` (novo)
**O que fazer:** Escrever testes para `paginate/2`:
- `paginate([], 1)` → `{[], 1}`
- `paginate(Enum.map(1..10, &"m#{&1}"), 1)` → lista com 8 items, total_pages = 2
- `paginate(Enum.map(1..10, &"m#{&1}"), 2)` → lista com 2 items, total_pages = 2
- `paginate(["a","b"], 99)` → clamp para page 1, total_pages = 1

---

### STORY-01.2 — Wiring no UpdatesProvider

#### TASK-01.2.1 XS
**Arquivo:** `lib/pincer/channels/telegram.ex`
**O que fazer:** Registrar o novo callback de paginação no `ChannelInteractionPolicy`.
Adicionar cláusula em `do_parse/1`:
```elixir
defp do_parse("page:" <> rest) do
  case String.split(rest, ":", parts: 2) do
    [provider_id, page_str] ->
      case Integer.parse(page_str) do
        {page, ""} when page >= 1 -> {:ok, {:page, provider_id, page}}
        _ -> {:error, :invalid_payload}
      end
    _ -> {:error, :invalid_payload}
  end
end
```
**Arquivo a editar:** `lib/pincer/core/channel_interaction_policy.ex`
Adicionar a cláusula acima **antes** da cláusula catch-all `defp do_parse(_)`.
Adicionar `{:ok, {:page, String.t(), pos_integer()}}` ao typespec `parse_result`.

---

#### TASK-01.2.2 S
**Arquivo:** `lib/pincer/channels/telegram.ex` (módulo `UpdatesProvider`)
**O que fazer:** Substituir o corpo de `handle_command(chat_id, "/models", ...)`:

```elixir
defp handle_command(chat_id, "/models", _text, _chat_type) do
  providers = Pincer.Ports.LLM.list_providers()
  buttons = build_provider_buttons(providers)
  if buttons == [] do
    interaction_unavailable(chat_id)
  else
    Pincer.Channels.Telegram.send_message(chat_id, "🔧 <b>Selecione o Provider:</b>",
      reply_markup: %Telegex.Type.InlineKeyboardMarkup{inline_keyboard: buttons}
    )
  end
end
```
Não mudar mais nada nesta função.

---

#### TASK-01.2.3 S
**Arquivo:** `lib/pincer/channels/telegram.ex` (módulo `UpdatesProvider`)
**O que fazer:** Adicionar handler no `handle_callback/4` para `{:ok, {:page, provider_id, page}}`:

```elixir
{:ok, {:page, provider_id, page}} ->
  models = Pincer.Ports.LLM.list_models(provider_id)
  session_id = session_id_for_chat(chat_id, chat_type)
  current_model = current_model_for_session(session_id)
  buttons = Pincer.Core.UX.ModelKeyboard.build_keyboard(provider_id, models, page, current_model)
  if buttons == [] do
    interaction_unavailable(chat_id)
  else
    edit_callback_message(
      chat_id, message_id,
      "🤖 <b>Modelos de #{provider_id} (página #{page}):</b>",
      reply_markup: %Telegex.Type.InlineKeyboardMarkup{inline_keyboard: buttons}
    )
  end
```
Adicionar esta cláusula **antes** da cláusula `{:ok, {:select_provider, provider_id}}`.

---

#### TASK-01.2.4 XS
**Arquivo:** `lib/pincer/channels/telegram.ex` (módulo `UpdatesProvider`)
**O que fazer:** Implementar `current_model_for_session/1` como função privada:
```elixir
defp current_model_for_session(session_id) do
  case Pincer.Core.Session.Server.get_status(session_id) do
    {:ok, %{model_override: %{model: model}}} -> model
    _ -> nil
  end
rescue
  _ -> nil
end
```

---

#### TASK-01.2.5 S
**Arquivo:** `lib/pincer/channels/telegram.ex` (módulo `UpdatesProvider`)
**O que fazer:** Modificar o handler `{:ok, {:select_provider, provider_id}}` para usar
`ModelKeyboard.build_keyboard/4` com `page = 1` em vez de `build_model_buttons/2`:

```elixir
{:ok, {:select_provider, provider_id}} ->
  models = Pincer.Ports.LLM.list_models(provider_id)
  session_id = session_id_for_chat(chat_id, chat_type)
  current_model = current_model_for_session(session_id)
  buttons = Pincer.Core.UX.ModelKeyboard.build_keyboard(provider_id, models, 1, current_model)
  if buttons == [] do
    interaction_unavailable(chat_id)
  else
    edit_callback_message(
      chat_id, message_id,
      "🤖 <b>Selecione o Modelo para #{provider_id}:</b>",
      reply_markup: %Telegex.Type.InlineKeyboardMarkup{inline_keyboard: buttons}
    )
  end
```

---

#### TASK-01.2.6 XS
**Arquivo:** `lib/pincer/channels/telegram.ex` (módulo `UpdatesProvider`)
**O que fazer:** Remover a função privada `build_model_buttons/2` (agora substituída por
`ModelKeyboard.build_keyboard/4`). Não remover `build_provider_buttons/1`.

---

---

## EPIC-02 🔴 — Comandos de controle de sessão nos canais (`/new`, `/model`, `/think`, `/reasoning`, `/verbose`, `/usage`)

**Motivação:** Usuário não consegue resetar sessão, trocar modelo por texto direto ou
controlar nível de raciocínio sem abrir o menu de botões.

---

### STORY-02.1 — `/new` e `/reset` para resetar sessão

#### TASK-02.1.1 XS
**Arquivo:** `lib/pincer/core/ux.ex`
**O que fazer:** Adicionar `%{name: "new", description: "Reinicia a sessão atual"}` e
`%{name: "reset", description: "Alias para /new"}` na lista `@commands`.

---

#### TASK-02.1.2 XS
**Arquivo:** `lib/pincer/core/ux.ex`
**O que fazer:** Adicionar as entradas `"new" => "/new"`, `"/new" => "/new"`,
`"reset" => "/new"`, `"/reset" => "/new"` no map `@shortcut_routes`.

---

#### TASK-02.1.3 XS
**Arquivo:** `lib/pincer/core/ux.ex`
**O que fazer:** Atualizar `help_text/1` adicionando a linha `/new    - Reinicia a sessão`
imediatamente após a linha do `/ping`.

---

#### TASK-02.1.4 S
**Arquivo:** `lib/pincer/channels/telegram.ex` (módulo `UpdatesProvider`)
**O que fazer:** Adicionar cláusula `handle_command(chat_id, "/new", ...)`:
```elixir
defp handle_command(chat_id, "/new", _text, chat_type) do
  session_id = session_id_for_chat(chat_id, chat_type)
  ensure_session_started(session_id)
  case Pincer.Core.Session.Server.reset(session_id) do
    :ok ->
      Pincer.Channels.Telegram.send_message(chat_id, "🔄 Sessão reiniciada.")
    _ ->
      Pincer.Channels.Telegram.send_message(chat_id, "❌ Não foi possível reiniciar a sessão.")
  end
end
```
Adicionar também `defp handle_command(chat_id, "/reset", text, chat_type), do: handle_command(chat_id, "/new", text, chat_type)`.

---

#### TASK-02.1.5 XS
**Arquivo:** `lib/pincer/channels/discord.ex` (ou `Pincer.Channels.Discord.UpdatesProvider`)
**O que fazer:** Replicar exatamente o mesmo handler `handle_command/4` para `/new` e
`/reset` no handler de Discord, usando `Pincer.Channels.Discord.send_message/2`.

---

### STORY-02.2 — `/model <provider/model>` troca direta

#### TASK-02.2.1 XS
**Arquivo:** `lib/pincer/core/ux.ex`
**O que fazer:** Adicionar `%{name: "model", description: "Troca o modelo: /model <provider/modelo>"}` em `@commands` e `"model" => "/model"`, `"/model" => "/model"` em `@shortcut_routes`.

---

#### TASK-02.2.2 S
**Arquivo:** `lib/pincer/channels/telegram.ex` (módulo `UpdatesProvider`)
**O que fazer:** Adicionar `handle_command(chat_id, "/model", text, chat_type)`:
```elixir
defp handle_command(chat_id, "/model", text, chat_type) do
  session_id = session_id_for_chat(chat_id, chat_type)
  ensure_session_started(session_id)
  case String.split(String.trim(text), "/", parts: 2) do
    [provider, model] when provider != "" and model != "" ->
      Pincer.Core.Session.Server.set_model(session_id, provider, model)
      Pincer.Channels.Telegram.send_message(
        chat_id, "✅ Modelo: <code>#{provider}/#{model}</code>")
    _ ->
      Pincer.Channels.Telegram.send_message(
        chat_id, "Uso: /model <provider/modelo>\nEx: /model openrouter/mistral-7b")
  end
end
```

---

#### TASK-02.2.3 XS
**Arquivo:** `lib/pincer/channels/discord.ex`
**O que fazer:** Replicar o handler `/model` no Discord com `Pincer.Channels.Discord.send_message/2`.

---

### STORY-02.3 — `/think <off|low|medium|high>` e `/reasoning <on|off>`

#### TASK-02.3.1 XS
**Arquivo:** `lib/pincer/core/session/server.ex`
**O que fazer:** Adicionar `:thinking_level` com valor padrão `nil` ao map de estado
no `init/1`:
```elixir
state = %{
  ...
  thinking_level: nil,
  reasoning_visible: false
}
```

---

#### TASK-02.3.2 S
**Arquivo:** `lib/pincer/core/session/server.ex`
**O que fazer:** Adicionar `handle_call({:set_thinking, level}, ...)`:
```elixir
@impl true
def handle_call({:set_thinking, level}, _from, state) do
  {:reply, :ok, %{state | thinking_level: level}}
end
```
E a função pública:
```elixir
def set_thinking(id, level),
  do: GenServer.call(via_tuple(id), {:set_thinking, level})
```

---

#### TASK-02.3.3 S
**Arquivo:** `lib/pincer/core/session/server.ex`
**O que fazer:** Adicionar `handle_call({:set_reasoning_visible, bool}, ...)`:
```elixir
@impl true
def handle_call({:set_reasoning_visible, visible}, _from, state) do
  {:reply, :ok, %{state | reasoning_visible: visible}}
end
```
E a função pública:
```elixir
def set_reasoning_visible(id, visible),
  do: GenServer.call(via_tuple(id), {:set_reasoning_visible, visible})
```

---

#### TASK-02.3.4 XS
**Arquivo:** `lib/pincer/core/ux.ex`
**O que fazer:** Adicionar em `@commands`:
```elixir
%{name: "think", description: "Nível de thinking: /think off|low|medium|high"},
%{name: "reasoning", description: "Exibir reasoning: /reasoning on|off"}
```
E em `@shortcut_routes`: `"think" => "/think"`, `"/think" => "/think"`,
`"reasoning" => "/reasoning"`, `"/reasoning" => "/reasoning"`.

---

#### TASK-02.3.5 S
**Arquivo:** `lib/pincer/channels/telegram.ex` (módulo `UpdatesProvider`)
**O que fazer:** Adicionar handler `/think`:
```elixir
defp handle_command(chat_id, "/think", text, chat_type) do
  session_id = session_id_for_chat(chat_id, chat_type)
  ensure_session_started(session_id)
  level = text |> String.trim() |> String.downcase()
  valid = ["off", "low", "medium", "high"]
  if level in valid do
    Pincer.Core.Session.Server.set_thinking(session_id, level)
    Pincer.Channels.Telegram.send_message(chat_id, "🧠 Thinking: <code>#{level}</code>")
  else
    Pincer.Channels.Telegram.send_message(
      chat_id, "Uso: /think off|low|medium|high")
  end
end
```

---

#### TASK-02.3.6 S
**Arquivo:** `lib/pincer/channels/telegram.ex` (módulo `UpdatesProvider`)
**O que fazer:** Adicionar handler `/reasoning`:
```elixir
defp handle_command(chat_id, "/reasoning", text, chat_type) do
  session_id = session_id_for_chat(chat_id, chat_type)
  ensure_session_started(session_id)
  case String.trim(text) |> String.downcase() do
    "on" ->
      Pincer.Core.Session.Server.set_reasoning_visible(session_id, true)
      Pincer.Channels.Telegram.send_message(chat_id, "👁 Reasoning: visível")
    "off" ->
      Pincer.Core.Session.Server.set_reasoning_visible(session_id, false)
      Pincer.Channels.Telegram.send_message(chat_id, "🙈 Reasoning: oculto (strip ativado)")
    _ ->
      Pincer.Channels.Telegram.send_message(chat_id, "Uso: /reasoning on|off")
  end
end
```

---

#### TASK-02.3.7 XS
**Arquivo:** `lib/pincer/channels/discord.ex`
**O que fazer:** Replicar os handlers `/think` e `/reasoning` no Discord.

---

### STORY-02.4 — `/verbose` e `/usage`

#### TASK-02.4.1 XS
**Arquivo:** `lib/pincer/core/session/server.ex`
**O que fazer:** Adicionar `:verbose` (bool, padrão `false`) e `:usage_display`
(`"off" | "tokens" | "full"`, padrão `"off"`) ao estado inicial no `init/1`.

---

#### TASK-02.4.2 S
**Arquivo:** `lib/pincer/core/session/server.ex`
**O que fazer:** Adicionar `handle_call({:set_verbose, bool}, ...)` e
`handle_call({:set_usage, level}, ...)` + funções públicas `set_verbose/2` e
`set_usage/2`.

---

#### TASK-02.4.3 S
**Arquivo:** `lib/pincer/channels/telegram.ex`
**O que fazer:** Adicionar handlers `/verbose on|off` e `/usage off|tokens|full`
seguindo o mesmo padrão dos handlers de `/think` e `/reasoning`.

---

---

## EPIC-03 🔴 — Reasoning stripping configurável por sessão

**Motivação:** Hoje o strip de `<thinking>` é sempre aplicado antes de enviar ao
usuário. Às vezes o desenvolvedor/operador quer ver o reasoning. A sessão deve expor
um flag.

---

#### TASK-03.1 XS
**Arquivo:** `lib/pincer/channels/telegram.ex`
**O que fazer:** Modificar `send_message/3` para aceitar `opts` com chave
`:skip_reasoning_strip`. Quando presente e `true`, pular o `strip_reasoning/1`:
```elixir
def send_message(chat_id, text, opts \\ []) do
  html_text =
    if Keyword.get(opts, :skip_reasoning_strip, false) do
      markdown_to_html(text)
    else
      text |> strip_reasoning() |> markdown_to_html()
    end
  do_send_message(chat_id, html_text, Keyword.put(opts, :parse_mode, "HTML"))
end
```
**Remover** o `strip_reasoning()` de dentro de `markdown_to_html/1` (não deve estar lá).

---

#### TASK-03.2 S
**Arquivo:** `lib/pincer/channels/telegram/session.ex`
**O que fazer:** Modificar `deliver_final/2` e `render_preview/3` para buscar o estado
`reasoning_visible` da sessão antes de entregar:
```elixir
defp send_opts_for_session(session_id) do
  case Pincer.Core.Session.Server.get_status(session_id) do
    {:ok, %{reasoning_visible: true}} -> [skip_reasoning_strip: true]
    _ -> []
  end
rescue
  _ -> []
end
```
Usar `send_opts_for_session(state.session_id)` ao chamar `send_message/3`.

---

#### TASK-03.3 XS
**Arquivo:** `test/pincer/channels/telegram_test.exs` (ou criar se não existir)
**O que fazer:** Adicionar dois testes para `send_message/3`:
1. Sem `:skip_reasoning_strip` — verifica que `<thinking>...</thinking>` é removido do output
2. Com `skip_reasoning_strip: true` — verifica que `<thinking>` **não** é removido

---

---

## EPIC-04 🟡 — Thinking levels propagados ao LLM (Anthropic `extended_thinking`)

**Motivação:** O estado `:thinking_level` já existe na sessão após EPIC-02. Agora
precisa ser passado ao provider Anthropic via parâmetro `thinking`.

---

#### TASK-04.1 XS
**Arquivo:** `lib/pincer/core/executor.ex`
**O que fazer:** Ao chamar `LLM.chat_completion/2`, passar o `:thinking_level` do
`model_override` nos opts:
```elixir
opts = [
  provider: provider_id,
  model: model_id,
  tools: tools
]
opts = if thinking = Map.get(model_override || %{}, :thinking_level) do
  Keyword.put(opts, :thinking_level, thinking)
else
  opts
end
```

---

#### TASK-04.2 S
**Arquivo:** `lib/pincer/llm/providers/anthropic.ex`
**O que fazer:** Em `chat_completion/4`, ler `config[:thinking_level]` e adicionar
o campo `thinking` ao body quando não for `nil` ou `"off"`:
```elixir
budget = case config[:thinking_level] do
  "low"    -> 4_000
  "medium" -> 10_000
  "high"   -> 20_000
  _        -> nil
end

body = if budget do
  Map.put(body, :thinking, %{type: "enabled", budget_tokens: budget})
else
  body
end
```
Adicionar o mapeamento **antes** da chamada `Req.post/2`.

---

#### TASK-04.3 XS
**Arquivo:** `lib/pincer/llm/providers/anthropic.ex`
**O que fazer:** Quando `thinking` estiver habilitado, o `max_tokens` deve ser pelo
menos `budget + 1`. Adicionar:
```elixir
max_tokens = max(config[:max_tokens] || 4096, (budget || 0) + 1)
body = Map.put(body, :max_tokens, max_tokens)
```
Logo após a lógica de `budget`.

---

#### TASK-04.4 XS
**Arquivo:** `test/pincer/llm/providers/anthropic_test.exs` (ou criar)
**O que fazer:** Adicionar teste que verifica que quando `config[:thinking_level] = "medium"`,
o body enviado contém `%{thinking: %{type: "enabled", budget_tokens: 10_000}}`.

---

---

## EPIC-05 🟡 — Security warning no onboarding

**Motivação:** OpenClaw exige aceite explícito de risco antes de configurar. Pincer
não exibe nenhum aviso de segurança.

---

#### TASK-05.1 XS
**Arquivo:** `lib/mix/tasks/pincer.onboard.ex`
**O que fazer:** Adicionar constante de aviso:
```elixir
@security_warning """
⚠️  AVISO DE SEGURANÇA — leia antes de continuar.

Pincer é um projeto em desenvolvimento. Com ferramentas habilitadas, o agente
pode ler arquivos, executar comandos e fazer requisições HTTP.
Um prompt malicioso pode induzir ações não desejadas.

Recomendações mínimas:
- Habilite apenas as ferramentas que você precisa.
- Não deixe secrets em arquivos acessíveis ao agente.
- Em ambientes multi-usuário, use sessões isoladas por usuário.
- Execute regularmente: mix pincer.security_audit
"""
```

---

#### TASK-05.2 XS
**Arquivo:** `lib/mix/tasks/pincer.onboard.ex`
**O que fazer:** Adicionar `@switches` a opção `accept_risk: :boolean`.

---

#### TASK-05.3 S
**Arquivo:** `lib/mix/tasks/pincer.onboard.ex`
**O que fazer:** Adicionar função privada `require_risk_acknowledgement/1` que:
1. Se `opts[:accept_risk]` for `true`, retorna `:ok` sem perguntar
2. Se `opts[:non_interactive]` for `true`, imprime o aviso e retorna `:ok`
3. Caso contrário: imprime `@security_warning`, lê prompt `"Entendido? [s/N]: "` e
   levanta `Mix.raise/1` se a resposta não for `"s"` ou `"sim"`.

---

#### TASK-05.4 XS
**Arquivo:** `lib/mix/tasks/pincer.onboard.ex`
**O que fazer:** Chamar `require_risk_acknowledgement(opts)` como primeira instrução
dentro de `run/1`, antes de qualquer outra lógica.

---

---

## EPIC-06 🟡 — Uso de tokens e custo por resposta (`/usage`)

**Motivação:** O usuário não vê quantos tokens está consumindo. O OpenClaw tem
`/usage off|tokens|full` que adiciona linha ao final de cada resposta.

---

#### TASK-06.1 XS
**Arquivo:** `lib/pincer/llm/providers/openai_compat.ex`
**O que fazer:** Modificar `handle_response/1` para extrair e retornar `usage` junto
com o message. O retorno deve ser `{:ok, message, usage}` onde `usage` é o mapa
`%{"prompt_tokens" => n, "completion_tokens" => n}` ou `nil`.

> **Atenção:** mudança de assinatura — verificar todos os callers antes de aplicar.

---

#### TASK-06.2 XS
**Arquivo:** `lib/pincer/ports/llm.ex` (behaviour)
**O que fazer:** Atualizar `@callback chat_completion/2` para retornar
`{:ok, message(), usage() | nil} | {:error, term()}`. Definir o type:
```elixir
@type usage :: %{String.t() => non_neg_integer()}
```

---

#### TASK-06.3 XS
**Arquivo:** `lib/pincer/llm/providers/anthropic.ex`
**O que fazer:** Extrair `usage` do body Anthropic (`body["usage"]`) e retornar
`{:ok, message, usage}`.

---

#### TASK-06.4 S
**Arquivo:** `lib/pincer/core/executor.ex`
**O que fazer:** Capturar `usage` do retorno de `LLM.chat_completion/2` e adicioná-lo
ao evento `{:executor_finished, final_history, response, usage}`. Se `usage` for `nil`,
enviar `nil`.

---

#### TASK-06.5 S
**Arquivo:** `lib/pincer/channels/telegram/session.ex`
**O que fazer:** Modificar `handle_info({:agent_response, text}, state)` para aceitar
também `{:agent_response, text, usage}`. Quando o estado da sessão tiver
`usage_display != "off"`, adicionar linha ao `text` antes de enviar:
```elixir
defp format_usage_line(nil, _display), do: ""
defp format_usage_line(_usage, "off"), do: ""
defp format_usage_line(usage, "tokens") do
  in_t = usage["prompt_tokens"] || 0
  out_t = usage["completion_tokens"] || 0
  "\n\n<i>📊 #{in_t} in · #{out_t} out</i>"
end
defp format_usage_line(usage, "full") do
  total = (usage["prompt_tokens"] || 0) + (usage["completion_tokens"] || 0)
  "\n\n<i>📊 total: #{total} tokens</i>"
end
```

---

---

## EPIC-07 🟡 — Cron service com persistência SQLite

**Motivação:** O `Pincer.Core.Cron` atual usa `Process.send_after` sem persistência.
Já existe `Pincer.Adapters.Cron.Storage` + `Pincer.Adapters.Cron.Scheduler` com
SQLite. Precisam ser conectados e expostos como API limpa.

---

### STORY-07.1 — API pública do Cron Core

#### TASK-07.1.1 XS
**Arquivo:** `lib/pincer/core/cron.ex`
**O que fazer:** Substituir o GenServer atual por um módulo de fachada que delega para
`Pincer.Adapters.Cron.Storage`. Manter a API existente `schedule/3` como compat shim
e adicionar:
```elixir
def add(attrs), do: Pincer.Adapters.Cron.Storage.create_job(attrs)
def list, do: Pincer.Adapters.Cron.Storage.list_jobs()
def remove(id), do: Pincer.Adapters.Cron.Storage.delete_job(id)
def disable(id), do: Pincer.Adapters.Cron.Storage.disable_job(id)
def enable(id), do: Pincer.Adapters.Cron.Storage.enable_job(id)
```

---

#### TASK-07.1.2 S
**Arquivo:** `lib/pincer/core/cron.ex`
**O que fazer:** Implementar `schedule/3` como compat shim usando `add/1`:
```elixir
def schedule(session_id, message, seconds_from_now) do
  run_at = DateTime.add(DateTime.utc_now(), seconds_from_now, :second)
  add(%{
    name: "one_shot_#{System.unique_integer([:positive])}",
    cron_expression: nil,
    run_once_at: run_at,
    prompt: message,
    session_id: session_id,
    enabled: true
  })
end
```
**Nota:** Se `Pincer.Adapters.Cron.Job` não tiver campo `run_once_at`, adicionar
migration e campo antes desta task.

---

#### TASK-07.1.3 XS
**Arquivo:** `lib/pincer/adapters/cron/scheduler.ex`
**O que fazer:** Verificar se o scheduler faz bootstrap dos jobs ao iniciar.
Se não fizer, adicionar no `init/1`:
```elixir
def init(_) do
  schedule_check()
  {:ok, %{}}
end
```
Sem mudar mais nada.

---

### STORY-07.2 — Tool de Cron para o agente

#### TASK-07.2.1 S
**Arquivo:** `lib/pincer/tools/scheduler.ex` (verificar se já existe; se sim, ler antes)
**O que fazer:** Garantir que a tool expõe a função `schedule_reminder/3`:
```elixir
def schedule_reminder(session_id, message, seconds) do
  Pincer.Core.Cron.schedule(session_id, message, seconds)
end
```
Registrar no `NativeToolRegistry` com schema JSON adequado.

---

---

## EPIC-08 🟡 — Canal Slack completo

**Motivação:** `Pincer.Channels.Slack` existe mas a implementação está incompleta.

---

### STORY-08.1 — Polling de eventos Slack

#### TASK-08.1.1 XS
**Arquivo:** `lib/pincer/channels/slack/session.ex` (ler primeiro)
**O que fazer:** Verificar se `Session` existe e tem o mesmo padrão de `Telegram.Session`.
Se não existir, criar copiando `Telegram.Session` e substituindo:
- `chat_id` → `channel_id`
- `Pincer.Channels.Telegram.*` → `Pincer.Channels.Slack.*`
- `"telegram_session_worker_"` → `"slack_session_worker_"`

---

#### TASK-08.1.2 S
**Arquivo:** `lib/pincer/channels/slack.ex`
**O que fazer:** Verificar se `send_message/3` está implementado com a Slack Web API.
Se não estiver, implementar usando `Req.post/2` ao endpoint
`https://slack.com/api/chat.postMessage` com `Authorization: Bearer <token>`.
Retornar `{:ok, ts}` (timestamp = message ID no Slack) ou `{:error, reason}`.

---

#### TASK-08.1.3 S
**Arquivo:** `lib/pincer/channels/slack.ex`
**O que fazer:** Implementar polling de eventos via `conversations.history` ou Events API.
Opção mais simples (polling): a cada 3s, chamar
`https://slack.com/api/conversations.history?channel=<id>&oldest=<last_ts>`.
Processar novas mensagens e roteá-las para `Session.Server.process_input/2`.

---

#### TASK-08.1.4 XS
**Arquivo:** `lib/pincer/channels/slack/session_supervisor.ex`
**O que fazer:** Verificar se `SessionSupervisor` existe e tem `start_session/2`.
Se não tiver, criar copiando `Telegram.SessionSupervisor` e adaptando nomes.

---

---

## EPIC-09 🟢 — Discord Inline Buttons (Nostrum Components)

**Motivação:** Discord suporta botões via Components API (Nostrum). O menu `/models`
no Discord é apenas texto; pode virar botões como no Telegram.

---

#### TASK-09.1 S
**Arquivo:** `lib/pincer/channels/discord.ex`
**O que fazer:** Implementar `send_message_with_components/3`:
```elixir
def send_message_with_components(channel_id, text, components) do
  Nostrum.Api.create_message(
    String.to_integer("#{channel_id}"),
    content: text,
    components: components
  )
end
```

---

#### TASK-09.2 S
**Arquivo:** `lib/pincer/channels/discord.ex` (handler de comandos)
**O que fazer:** Modificar o handler `/models` no Discord para construir e enviar
botões de provider usando Nostrum ActionRow + Button:
```elixir
providers = Pincer.Ports.LLM.list_providers()
components = Enum.map(providers, fn p ->
  %{type: 2, label: p.name, style: 1,
    custom_id: "select_provider:#{p.id}"}
end)
action_row = %{type: 1, components: components}
send_message_with_components(channel_id, "🔧 Selecione o Provider:", [action_row])
```

---

#### TASK-09.3 S
**Arquivo:** `lib/pincer/channels/discord.ex`
**O que fazer:** Adicionar handler para `interaction_create` no consumer do Discord que
lida com `custom_id` começando com `"select_provider:"` e `"select_model:"`:
```elixir
def handle_event({:INTERACTION_CREATE, %{data: %{custom_id: "select_provider:" <> pid}, ...}, _}) do
  # listar modelos e enviar novo ActionRow com botões de modelo
end
```

---

---

## EPIC-10 🟢 — Token Counter e custo por provider no status

**Motivação:** O `/status` atual mostra apenas o estado da sessão. Deve mostrar
o provider/modelo ativo e contagem acumulada de tokens da sessão.

---

#### TASK-10.1 XS
**Arquivo:** `lib/pincer/core/session/server.ex`
**O que fazer:** Adicionar `:token_usage_total` ao estado inicial:
```elixir
token_usage_total: %{"prompt_tokens" => 0, "completion_tokens" => 0}
```

---

#### TASK-10.2 XS
**Arquivo:** `lib/pincer/core/session/server.ex`
**O que fazer:** No handler `{:executor_finished, final_history, response, usage}`,
acumular o uso:
```elixir
new_totals = %{
  "prompt_tokens" => state.token_usage_total["prompt_tokens"] + (usage["prompt_tokens"] || 0),
  "completion_tokens" => state.token_usage_total["completion_tokens"] + (usage["completion_tokens"] || 0)
}
{:noreply, %{state | token_usage_total: new_totals, ...}}
```

---

#### TASK-10.3 S
**Arquivo:** `lib/pincer/core/project_router.ex`
**O que fazer:** Modificar `handle_command(:status, nil, session_id)` para incluir
modelo ativo e tokens acumulados na resposta:
```
Sessão: telegram_123456
Modelo: openrouter/mistral-7b
Tokens esta sessão: 1.234 in · 876 out
Status: idle
```

---

---

## EPIC-11 🟢 — Onboarding auth choice agrupado

**Motivação:** O onboard atual pergunta provider e model como texto livre. Deve
oferecer uma lista curada de opções com hints.

---

#### TASK-11.1 S
**Arquivo:** `lib/mix/tasks/pincer.onboard.ex`
**O que fazer:** Substituir os prompts de `provider` e `model` por um menu de
seleção numerado quando em modo interativo:
```
Selecione o provider LLM:
  1) openrouter      (OpenRouter — acesso a vários modelos)
  2) z_ai            (Z.AI / ZhiPu — gratuito)
  3) opencode_zen    (OpenCode Zen — Kimi gratuito)
  4) google          (Google Gemini)
  5) moonshot        (Moonshot / Kimi)
  6) anthropic       (Claude)
  7) Outro (digitar)
```
Implementar como uma função `prompt_provider_choice/1` que retorna o provider_id escolhido.

---

#### TASK-11.2 S
**Arquivo:** `lib/mix/tasks/pincer.onboard.ex`
**O que fazer:** Após a escolha de provider, exibir os modelos padrão conhecidos para
aquele provider (hardcoded no próprio wizard) e pedir confirmação ou entrada manual:
```
Modelos disponíveis para openrouter:
  1) openrouter/free (padrão)
  2) openrouter/mistral-7b
  3) Outro (digitar)
```
Implementar como `prompt_model_for_provider/1` que retorna o model_id.

---

#### TASK-11.3 XS
**Arquivo:** `lib/mix/tasks/pincer.onboard.ex`
**O que fazer:** Garantir que em `--non-interactive`, `--provider` e `--model` continuam
funcionando exatamente como antes (sem regressão).

---

---

## EPIC-12 🟢 — Gateway HTTP mínimo para integração externa

**Motivação:** Permite que apps externas (ou testes de integração) enviem mensagens
ao Pincer via HTTP sem depender de um canal de mensagens.

---

#### TASK-12.1 S
**Arquivo:** `lib/pincer/channels/webhook.ex` (verificar implementação atual)
**O que fazer:** Garantir que existe um endpoint `POST /api/v1/message` que aceita:
```json
{"session_id": "telegram_123", "text": "olá"}
```
e chama `Pincer.Core.Session.Supervisor.start_session/1` + `Session.Server.process_input/2`.
Retornar `{"status": "queued"}` com status 202.

---

#### TASK-12.2 XS
**Arquivo:** `lib/pincer/channels/webhook.ex`
**O que fazer:** Adicionar autenticação Bearer token ao endpoint. Ler o token de
`Application.get_env(:pincer, :webhook_token)`. Se o header `Authorization` não
corresponder, retornar 401.

---

#### TASK-12.3 XS
**Arquivo:** `config/config.exs`
**O que fazer:** Adicionar:
```elixir
config :pincer, :webhook_token, System.get_env("PINCER_WEBHOOK_TOKEN", "")
```

---

#### TASK-12.4 S
**Arquivo:** `lib/pincer/channels/webhook.ex`
**O que fazer:** Adicionar endpoint `GET /api/v1/sessions` que lista as sessões
ativas usando `Registry.select/2` no `Pincer.Core.Session.Registry`.
Retornar `{"sessions": ["telegram_123", "discord_456"]}`.

---

---

## Rastreamento de Progresso

| Epic | Título | Status |
|---|---|---|
| EPIC-01 | Inline buttons Telegram paginados | ⬜ |
| EPIC-02 | Comandos `/new`, `/model`, `/think`, `/reasoning`, `/verbose`, `/usage` | ⬜ |
| EPIC-03 | Reasoning stripping configurável por sessão | ⬜ |
| EPIC-04 | Thinking levels para Anthropic | ⬜ |
| EPIC-05 | Security warning no onboard | ⬜ |
| EPIC-06 | Token counter e custo por resposta | ⬜ |
| EPIC-07 | Cron service com persistência SQLite | ⬜ |
| EPIC-08 | Canal Slack completo | ⬜ |
| EPIC-09 | Discord Inline Buttons | ⬜ |
| EPIC-10 | Token counter no `/status` | ⬜ |
| EPIC-11 | Onboarding auth choice agrupado | ⬜ |
| EPIC-12 | Gateway HTTP mínimo | ⬜ |

---

## Guia de execução para agentes

Ao receber uma task deste ROADMAP:

1. **Leia apenas o arquivo mencionado na task antes de editar.** Não leia outros arquivos
   a menos que a task instrua explicitamente.
2. **Faça apenas o que a task descreve.** Não refatore código ao redor, não adicione
   comentários extras, não mude testes existentes.
3. **Se o arquivo não existir**, criá-lo com apenas o conteúdo descrito.
4. **Se a task menciona um teste**, escreva apenas os casos listados — sem adicionar
   outros cenários não pedidos.
5. **Quando terminar**, relatar: arquivo editado, função adicionada/modificada, e se
   compila sem erros (`mix compile`).
