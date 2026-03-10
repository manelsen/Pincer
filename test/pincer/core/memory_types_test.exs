defmodule Pincer.Core.MemoryTypesTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.MemoryTypes

  test "normalize/1 canonicalizes supported memory types" do
    assert MemoryTypes.normalize(:technical_fact) == "technical_fact"
    assert MemoryTypes.normalize("User Preference") == "user_preference"
    assert MemoryTypes.normalize("architecture-decision") == "architecture_decision"
    assert MemoryTypes.normalize("unknown-value") == "reference"
  end

  test "valid?/1 accepts only supported memory types" do
    assert MemoryTypes.valid?("bug_solution")
    assert MemoryTypes.valid?(:session_summary)
    refute MemoryTypes.valid?("whatever")
  end
end
