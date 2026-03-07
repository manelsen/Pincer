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
end
