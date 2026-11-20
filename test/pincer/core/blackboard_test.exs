defmodule Pincer.Core.BlackboardTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Orchestration.Blackboard

  setup do
    Blackboard.reset()

    on_exit(fn ->
      Blackboard.reset()
    end)

    :ok
  end

  test "fetch_new/2 filters messages by scope" do
    _ = Blackboard.post("system", "Annie update", nil, scope: "annie")
    _ = Blackboard.post("system", "Lucie update", nil, scope: "lucie")

    {annie_messages, annie_last_id} = Blackboard.fetch_new(0, scope: "annie")
    {lucie_messages, lucie_last_id} = Blackboard.fetch_new(0, scope: "lucie")

    assert Enum.map(annie_messages, & &1.content) == ["Annie update"]
    assert Enum.all?(annie_messages, &(&1.scope == "annie"))
    assert annie_last_id > 0

    assert Enum.map(lucie_messages, & &1.content) == ["Lucie update"]
    assert Enum.all?(lucie_messages, &(&1.scope == "lucie"))
    assert lucie_last_id > 0
  end

  test "post/4 persists the structured kind so consumers do not parse text" do
    id =
      Blackboard.post("Architect", "some plan text", "proj-1",
        scope: "session-1",
        kind: :plan_generated
      )

    assert is_integer(id)
    {[message], _} = Blackboard.fetch_new(0, scope: "session-1")

    assert message.kind == :plan_generated
    assert message.content == "some plan text"
  end

  test "kind defaults to nil when the producer omits it" do
    _id = Blackboard.post("Architect", "plain note", nil, scope: "session-2")

    {[message], _} = Blackboard.fetch_new(0, scope: "session-2")

    assert message.kind == nil
  end
end
