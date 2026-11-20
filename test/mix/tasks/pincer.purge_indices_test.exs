defmodule Mix.Tasks.Pincer.PurgeIndicesTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Pincer.PurgeIndices
  alias Pincer.Infra.Repo
  alias Pincer.Storage.Graph.Node

  setup do
    Application.ensure_all_started(:pincer)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.delete_all(Node)
    :ok
  end

  test "purge/1 deletes only document nodes under tmp/ and workspaces/ using Postgres JSONB" do
    tmp_doc =
      Repo.insert!(%Node{type: "document", data: %{"path" => "tmp/scratch.md"}})

    ws_doc =
      Repo.insert!(%Node{type: "document", data: %{"path" => "workspaces/agent_1/notes.md"}})

    valid_doc =
      Repo.insert!(%Node{type: "document", data: %{"path" => "lib/pincer/app.ex"}})

    non_doc_tmp =
      Repo.insert!(%Node{type: "file", data: %{"path" => "tmp/file_node.ex"}})

    no_path_doc =
      Repo.insert!(%Node{type: "document", data: %{"title" => "untitled"}})

    assert {2, _} = PurgeIndices.purge(Repo)

    remaining_ids =
      Repo.all(Node)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    refute MapSet.member?(remaining_ids, tmp_doc.id)
    refute MapSet.member?(remaining_ids, ws_doc.id)
    assert MapSet.member?(remaining_ids, valid_doc.id)
    assert MapSet.member?(remaining_ids, non_doc_tmp.id)
    assert MapSet.member?(remaining_ids, no_path_doc.id)
  end
end
