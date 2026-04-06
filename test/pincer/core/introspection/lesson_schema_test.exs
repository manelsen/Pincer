defmodule Pincer.Core.Introspection.LessonSchemaTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Introspection.LessonSchema

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      cs =
        LessonSchema.changeset(%LessonSchema{}, %{
          agent_id: "agent_1",
          content: "Always validate inputs before processing."
        })

      assert cs.valid?
    end

    test "agent_id and content are required" do
      cs = LessonSchema.changeset(%LessonSchema{}, %{})
      refute cs.valid?
      assert {"can't be blank", _} = cs.errors[:agent_id]
      assert {"can't be blank", _} = cs.errors[:content]
    end

    test "confidence must be between 0.0 and 1.0" do
      base = %{agent_id: "a", content: "lesson"}

      cs_low = LessonSchema.changeset(%LessonSchema{}, Map.put(base, :confidence, -0.1))
      refute cs_low.valid?

      cs_high = LessonSchema.changeset(%LessonSchema{}, Map.put(base, :confidence, 1.1))
      refute cs_high.valid?

      cs_ok = LessonSchema.changeset(%LessonSchema{}, Map.put(base, :confidence, 0.75))
      assert cs_ok.valid?
    end

    test "source must be valid" do
      base = %{agent_id: "a", content: "lesson"}

      for s <- ~w(reflection episode manual) do
        cs = LessonSchema.changeset(%LessonSchema{}, Map.put(base, :source, s))
        assert cs.valid?, "expected source #{s} to be valid"
      end

      cs_bad = LessonSchema.changeset(%LessonSchema{}, Map.put(base, :source, "invalid"))
      refute cs_bad.valid?
    end

    test "defaults are applied" do
      cs =
        LessonSchema.changeset(%LessonSchema{}, %{
          agent_id: "a",
          content: "lesson"
        })

      assert Ecto.Changeset.get_field(cs, :confidence) == 0.5
      assert Ecto.Changeset.get_field(cs, :source) == "reflection"
      assert Ecto.Changeset.get_field(cs, :success_count) == 0
      assert Ecto.Changeset.get_field(cs, :failure_count) == 0
      assert Ecto.Changeset.get_field(cs, :contradiction_penalty) == 0.0
      assert Ecto.Changeset.get_field(cs, :active) == true
    end
  end
end
