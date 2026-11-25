defmodule Pincer.Adapters.Storage.IntrospectionTest do
  use ExUnit.Case, async: false

  alias Pincer.Infra.SQLite
  alias Pincer.Ports.IntrospectionStore

  test "reads existing lesson and self-state records with decoded fields" do
    agent = "introspection-#{System.unique_integer([:positive])}"
    timestamp = "2026-01-01T00:00:00Z"

    assert :ok =
             SQLite.execute(
               SQLite.default_server(),
               """
               INSERT INTO lessons
                 (id, agent_id, content, confidence, meta, inserted_at, updated_at)
               VALUES (?, ?, 'Keep the record', 0.8, '{"saved":true}', ?, ?)
               """,
               [agent, agent, timestamp, timestamp]
             )

    assert :ok =
             SQLite.execute(
               SQLite.default_server(),
               """
               INSERT INTO self_states
                 (id, agent_id, open_questions, inserted_at, updated_at)
               VALUES (?, ?, '["What changed?"]', ?, ?)
               """,
               [agent, agent, timestamp, timestamp]
             )

    assert [%{id: ^agent, confidence: 0.8, active: true, meta: %{"saved" => true}}] =
             IntrospectionStore.list_lessons(agent, {:top, 1, 0.8})

    assert [] = IntrospectionStore.list_lessons(agent, {:top, 1, 0.81})

    assert {:ok, %{agent_id: ^agent, open_questions: ["What changed?"], focus: ""}} =
             IntrospectionStore.get_self_state(agent)

    assert {:ok, nil} = IntrospectionStore.get_self_state(agent <> "-missing")
  end
end
