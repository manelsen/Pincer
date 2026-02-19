defmodule Pincer.Storage.Adapters.SQLite do
  @moduledoc """
  Adapter for SQLite storage.
  """
  @behaviour Pincer.Storage.Port

  alias Pincer.Repo
  alias Pincer.Storage.Message
  alias Pincer.AI.Embeddings
  import Ecto.Query
  require Logger

  @impl true
  def get_messages(session_id) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
    |> Enum.map(fn m -> %{role: m.role, content: m.content} end)
  end

  @impl true
  def save_message(session_id, role, content) do
    case %Message{}
         |> Message.changeset(%{session_id: session_id, role: role, content: content})
         |> Repo.insert() do
      {:ok, message} ->
        # Dispara geração de embedding em background
        Task.start(fn ->
          index_message(message)
        end)

        {:ok, message}

      error ->
        error
    end
  end

  @doc """
  Busca as mensagens mais similares semanticamente a uma query.
  """
  def search_similar_messages(query_text, limit \\ 5) do
    # 1. Gera embedding para a query usando o Serving global
    query_vector = Embeddings.generate(query_text)

    # 2. Busca TODAS as mensagens que possuem embedding
    messages = 
      Message
      |> where([m], not is_nil(m.embedding))
      |> Repo.all()

    # 3. Calcula similaridade de cosseno em massa usando Nx
    messages
    |> Enum.map(fn msg ->
      msg_vector = Nx.from_binary(msg.embedding, :f32)
      similarity = Embeddings.similarity(query_vector, msg_vector)
      {msg, similarity}
    end)
    |> Enum.sort_by(fn {_, sim} -> sim end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {msg, _} -> %{role: msg.role, content: msg.content} end)
  end

  defp index_message(message) do
    try do
      # Gera o embedding usando o Serving global
      case Embeddings.generate(message.content) do
        nil -> 
          Logger.warning("Falha ao gerar embedding para mensagem #{message.id} (retornou nil)")
        
        embedding ->
          # Serializa o tensor para binary
          embedding_binary = Nx.to_binary(embedding)

          message
          |> Message.changeset(%{embedding: embedding_binary})
          |> Repo.update()
          
          Logger.info("Mensagem indexada com sucesso (ID: #{message.id})")
      end
    rescue
      e -> Logger.error("Erro ao indexar mensagem: #{inspect(e)}")
    end
  end
end
