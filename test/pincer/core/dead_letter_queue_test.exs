defmodule Pincer.Core.DeadLetterQueueTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.DeadLetterQueue
  alias Pincer.Infra.Repo

  setup do
    Repo.delete_all(DeadLetterQueue)
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
end
