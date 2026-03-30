defmodule Pincer.Core.BlackboardIsolationTest do
  use ExUnit.Case
  alias Pincer.Core.Orchestration.Blackboard

  setup do
    Blackboard.reset()
    :ok
  end

  test "fetch_new with nil scope returns only global messages" do
    # Post a private message
    Blackboard.post("agent-1", "Private info", "proj-1", scope: "private-session")

    # Post a global message
    Blackboard.post("agent-2", "Public info", "proj-1", scope: :global)

    # Fetch with nil scope (simulating a default/unscoped request)
    {messages, _last_id} = Blackboard.fetch_new(0, scope: nil)

    assert length(messages) == 1
    assert Enum.at(messages, 0).content == "Public info"
    assert Enum.at(messages, 0).scope == :global
  end

  test "fetch_new with specific scope returns only that scope's messages" do
    Blackboard.post("agent-1", "Session A", "proj-1", scope: "session-a")
    Blackboard.post("agent-2", "Session B", "proj-1", scope: "session-b")
    Blackboard.post("agent-3", "Global", "proj-1", scope: :global)

    {messages, _last_id} = Blackboard.fetch_new(0, scope: "session-a")

    assert length(messages) == 1
    assert Enum.at(messages, 0).content == "Session A"
  end

  test "fetch_new with :all scope returns everything (for internal use)" do
    Blackboard.post("agent-1", "Private", "proj-1", scope: "private")
    Blackboard.post("agent-2", "Global", "proj-1", scope: :global)

    {messages, _last_id} = Blackboard.fetch_new(0, scope: :all)

    assert length(messages) == 2
  end
end
