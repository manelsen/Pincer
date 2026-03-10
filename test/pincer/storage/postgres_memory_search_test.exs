defmodule Pincer.Storage.PostgresMemorySearchTest do
  use ExUnit.Case, async: false

  alias Pincer.Infra.Repo
  alias Pincer.Storage.Adapters.Postgres

  setup do
    Application.ensure_all_started(:pincer)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    {:ok, _} = Ecto.Adapters.SQL.query(Repo, "DELETE FROM edges", [])
    {:ok, _} = Ecto.Adapters.SQL.query(Repo, "DELETE FROM nodes", [])
    {:ok, _} = Ecto.Adapters.SQL.query(Repo, "DELETE FROM messages", [])

    :ok
  end

  test "search_messages/2 returns cited FTS hits from persisted history" do
    session_id = "fts_session_#{System.unique_integer([:positive])}"
    content = "The deploy timeout was fixed by increasing the webhook timeout to 60 seconds."

    assert {:ok, _message} = Postgres.save_message(session_id, "assistant", content)
    assert {:ok, results} = Postgres.search_messages("deploy timeout webhook", 5)

    assert Enum.any?(results, fn result ->
             result.content == content and
               result.source =~ "session:#{session_id}:message:" and
               result.citation =~ "session #{session_id}"
           end)
  end

  test "search_documents/2 and search_similar/3 return indexed snippets" do
    path = "session://postgres/snippet/#{System.unique_integer([:positive])}"
    content = "Retry storms usually point to webhook drift after deployments."
    vector = [1.0, 0.0, 0.0]

    assert :ok = Postgres.index_document(path, content, vector)
    assert {:ok, text_results} = Postgres.search_documents("retry storms webhook", 5)
    assert {:ok, semantic_results} = Postgres.search_similar("document", vector, 5)

    assert Enum.any?(text_results, fn result ->
             result.content == content and result.source == path and result.citation == path
           end)

    assert Enum.any?(semantic_results, fn result ->
             result.content == content and result.source == path and result.citation == path
           end)
  end
end
