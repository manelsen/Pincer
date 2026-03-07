defmodule Pincer.Core.SelfImprovementTest do
  use ExUnit.Case, async: false
  alias Pincer.Ports.Storage

  setup do
    # Ensure Repo is started
    Application.ensure_all_started(:pincer)
    
    # Clean up test nodes
    Pincer.Infra.Repo.delete_all(Pincer.Storage.Graph.Node)
    :ok
  end

  test "captures tool errors into the knowledge graph" do
    Storage.save_tool_error("test_tool", %{"arg" => 1}, "Crash!")
    
    learnings = Storage.list_recent_learnings(1)
    assert length(learnings) == 1
    assert hd(learnings).type == :error
    assert hd(learnings).tool == "test_tool"
    assert hd(learnings).error == "Crash!"
  end

  test "/learn command persists a new lesson" do
    text = "/learn Always use pattern matching"
    {:ok, cmd, args} = Pincer.Core.ProjectRouter.parse(text)
    Pincer.Core.ProjectRouter.handle_command(cmd, args, "cli_user")
    
    learnings = Storage.list_recent_learnings(1)
    assert length(learnings) == 1
    assert hd(learnings).type == :learning
    assert hd(learnings).summary == "Always use pattern matching"
  end
end
