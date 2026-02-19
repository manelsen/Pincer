# SPECS.md - Documentação Técnica Pincer (Protocolo Batedor)

Este relatório consolida as especificações técnicas das bibliotecas essenciais para o projeto Pincer, extraídas da documentação oficial em https://hexdocs.pm em 2026-02-18.

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
