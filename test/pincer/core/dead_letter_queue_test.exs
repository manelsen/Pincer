defmodule Pincer.Core.DeadLetterQueueTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.DeadLetterQueue
  alias Pincer.Infra.SQLite

  setup do
    :ok = SQLite.execute("DELETE FROM dead_letter_queue")
    :ok
  end

  test "enqueues a failed operation" do
    payload = %{"action" => "send_message", "text" => "hello"}
    assert {:ok, entry} = DeadLetterQueue.enqueue("telegram_delivery", payload, "timeout")

    assert entry.operation_type == "telegram_delivery"
    assert entry.payload == payload
    assert entry.error =~ "timeout"
    assert is_nil(entry.resolved_at)
  end

  test "lists pending entries" do
    DeadLetterQueue.enqueue("op1", %{"id" => 1})
    DeadLetterQueue.enqueue("op2", %{"id" => 2})

    pending = DeadLetterQueue.pending()
    assert length(pending) == 2
  end

  test "resolves an entry" do
    {:ok, entry} = DeadLetterQueue.enqueue("op", %{"id" => 1})
    assert {:ok, resolved} = DeadLetterQueue.resolve(entry.id, "fixed by user")

    assert resolved.resolved_at != nil
    assert resolved.resolution == "fixed by user"
    assert DeadLetterQueue.pending() == []
  end

  test "increments attempt count" do
    {:ok, entry} = DeadLetterQueue.enqueue("op", %{"id" => 1})
    assert entry.attempt_count == 1

    {:ok, updated} = DeadLetterQueue.increment_attempt(entry.id)
    assert updated.attempt_count == 2
  end

  test "parallel retry results preserve every increment and the resolution" do
    {:ok, entry} = DeadLetterQueue.enqueue("parallel", %{"id" => 1})
    {:ok, _resolved} = DeadLetterQueue.resolve(entry.id, "handled")

    attempts =
      1..12
      |> Task.async_stream(fn _ -> DeadLetterQueue.increment_attempt(entry.id) end,
        max_concurrency: 6
      )
      |> Enum.map(fn {:ok, {:ok, updated}} ->
        assert updated.resolution == "handled"
        updated.attempt_count
      end)

    assert Enum.sort(attempts) == Enum.to_list(2..13)
    assert DeadLetterQueue.pending("parallel") == []
  end
end
