defmodule Pincer.MixAliasesTest do
  use ExUnit.Case, async: true

  test "project defines DX aliases for quick feedback loops" do
    aliases = Mix.Project.config()[:aliases] || []

    assert Keyword.has_key?(aliases, :qa)
    assert Keyword.has_key?(aliases, :"test.quick")
    assert Keyword.has_key?(aliases, :"sprint.check")
  end
end
