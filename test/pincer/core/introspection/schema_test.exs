defmodule Pincer.Core.Introspection.SchemaTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Introspection.Schema

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs = Schema.changeset(%Schema{}, %{agent_id: "agent_1"})
      assert cs.valid?
    end

    test "agent_id is required" do
      cs = Schema.changeset(%Schema{}, %{})
      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:agent_id]
    end

    test "wakefulness must be one of idle, active, reflecting" do
      cs = Schema.changeset(%Schema{}, %{agent_id: "a", wakefulness: "invalid"})
      refute cs.valid?
      assert {"is invalid", _} = cs.errors[:wakefulness]
    end

    test "valid wakefulness values are accepted" do
      for w <- ~w(idle active reflecting) do
        cs = Schema.changeset(%Schema{}, %{agent_id: "a", wakefulness: w})
        assert cs.valid?, "expected #{w} to be valid"
      end
    end

    test "defaults are applied" do
      cs = Schema.changeset(%Schema{}, %{agent_id: "a"})
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :wakefulness) == "idle"
      assert Ecto.Changeset.get_field(cs, :focus) == ""
      assert Ecto.Changeset.get_field(cs, :concerns) == []
      assert Ecto.Changeset.get_field(cs, :open_questions) == []
      assert Ecto.Changeset.get_field(cs, :mood_valence) == 0.0
      assert Ecto.Changeset.get_field(cs, :mood_arousal) == 0.0
      assert Ecto.Changeset.get_field(cs, :meta) == %{}
    end

    test "all fields can be cast" do
      cs =
        Schema.changeset(%Schema{}, %{
          agent_id: "a",
          wakefulness: "active",
          focus: "testing",
          concerns: ["c1", "c2"],
          open_questions: ["q1"],
          work_lanes: [%{"title" => "lane1", "status" => "active"}],
          last_reflection_summary: "all good",
          mood_valence: 0.5,
          mood_arousal: 0.3,
          meta: %{"key" => "value"}
        })

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :focus) == "testing"
      assert Ecto.Changeset.get_field(cs, :concerns) == ["c1", "c2"]
    end
  end
end
