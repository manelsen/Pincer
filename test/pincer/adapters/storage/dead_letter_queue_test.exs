defmodule Pincer.Adapters.Storage.DeadLetterQueueTest do
  use ExUnit.Case, async: false

  alias Pincer.Infra.SQLite
  alias Pincer.Ports.DeadLetterQueue

  test "loads and retries an operation persisted in the original schema" do
    id = "dlq-#{System.unique_integer([:positive])}"

    assert :ok =
             SQLite.execute(
               SQLite.default_server(),
               """
               INSERT INTO dead_letter_queue
                 (id, operation_type, payload, attempt_count, inserted_at, updated_at)
               VALUES (?, ?, '{"action":"deliver"}', 3, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
               """,
               [id, id]
             )

    assert [%{id: ^id, payload: %{"action" => "deliver"}, attempt_count: 3}] =
             DeadLetterQueue.pending(id)

    now = DateTime.utc_now()
    assert {:ok, %{attempt_count: 4}} = DeadLetterQueue.increment_attempt(id, now)

    assert {:ok, %{attempt_count: 4, resolved_at: ^now}} =
             DeadLetterQueue.resolve(id, "fixed", now)

    assert [] = DeadLetterQueue.pending(id)
    assert {:error, :not_found} = DeadLetterQueue.increment_attempt(id <> "-missing", now)
  end
end
