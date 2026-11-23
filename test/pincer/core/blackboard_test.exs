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

  test "a restart keeps the hot cache and does not reuse ids" do
    first_id = Blackboard.post("system", "before restart", nil, scope: "restart-test")
    assert is_integer(first_id)

    original = Process.whereis(Blackboard)
    Process.exit(original, :kill)
    restarted = wait_for_blackboard_restart(original)

    second_id = Blackboard.post("system", "after restart", nil, scope: "restart-test")
    assert second_id > first_id

    {messages, _} = Blackboard.fetch_new(0, scope: "restart-test")
    assert Enum.map(messages, & &1.content) == ["before restart", "after restart"]
    assert Process.whereis(Blackboard) == restarted
  end

  defp wait_for_blackboard_restart(original, attempts \\ 100) do
    case Process.whereis(Blackboard) do
      pid when is_pid(pid) and pid != original ->
        pid

      _ when attempts == 0 ->
        flunk("Blackboard did not restart after being killed")

      _ ->
        Process.sleep(10)
        wait_for_blackboard_restart(original, attempts - 1)
    end
  end
end
