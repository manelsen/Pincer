defmodule Mix.Tasks.Pincer.MemoryExplainTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Pincer.Core.AgentPaths
  alias Pincer.Infra.Repo
  alias Pincer.Storage.Adapters.Postgres

  @task "pincer.memory.explain"

  setup do
    Application.ensure_all_started(:pincer)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    {:ok, _} = Ecto.Adapters.SQL.query(Repo, "DELETE FROM edges", [])
    {:ok, _} = Ecto.Adapters.SQL.query(Repo, "DELETE FROM nodes", [])
    {:ok, _} = Ecto.Adapters.SQL.query(Repo, "DELETE FROM messages", [])

    tmp =
      Path.join(
        System.tmp_dir!(),
        "pincer_memory_explain_task_#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(tmp, "workspaces/explain")
    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)

    File.write!(
      AgentPaths.user_path(workspace),
      """
      # User

      ## Learned User Memory
      - Prefers concise postmortems.
      """
    )

    on_exit(fn ->
      File.rm_rf!(tmp)
      Mix.Task.reenable(@task)
    end)

    {:ok, %{workspace: workspace}}
  end

  test "prints explain output without semantic search when --no-semantic is used", %{
    workspace: workspace
  } do
    assert {:ok, _} =
             Postgres.save_message(
               "session-a",
               "assistant",
               "Deploy timeout was fixed after webhook retries were limited."
             )

    assert :ok =
             Postgres.index_memory(
               "session://explain/snippet/1",
               "Deploy timeout runbook says to inspect webhook retries first.",
               "technical_fact",
               [1.0, 0.0],
               importance: 8,
               session_id: "session-a"
             )

    output =
      capture_io(fn ->
        Mix.Task.run(@task, [
          "--query",
          "deploy timeout webhook",
          "--workspace-path",
          workspace,
          "--limit",
          "5",
          "--no-semantic"
        ])
      end)

    assert output =~ "Pincer Memory Explain"
    assert output =~ "Query: deploy timeout webhook"
    assert output =~ "Eligible: yes"
    assert output =~ "Source hits: messages=1 documents=1 semantic=0 graph=0"
    assert output =~ "Prefers concise postmortems."
    assert output =~ "session://explain/snippet/1"
    assert output =~ "session-a"
  end
end
