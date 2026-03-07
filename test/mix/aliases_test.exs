defmodule Pincer.MixAliasesTest do
  use ExUnit.Case, async: true

  test "project defines DX aliases for quick feedback loops" do
    aliases = Mix.Project.config()[:aliases] || []

    assert Keyword.has_key?(aliases, :qa)
    assert Keyword.has_key?(aliases, :"test.quick")
    assert Keyword.has_key?(aliases, :"sprint.check")
  end

  test "project enforces warnings as errors in compile and DX aliases" do
    config = Mix.Project.config()
    aliases = config[:aliases] || []

    assert Keyword.get(config[:elixirc_options] || [], :warnings_as_errors) == true
    assert Enum.member?(aliases[:qa] || [], "compile --warnings-as-errors")
    assert Enum.member?(aliases[:qa] || [], "test --warnings-as-errors --max-failures 1")

    assert Enum.member?(
             aliases[:"test.quick"] || [],
             "test --warnings-as-errors --stale --max-failures 1"
           )

    assert Enum.member?(aliases[:"sprint.check"] || [], "compile --warnings-as-errors")
    assert Enum.member?(aliases[:"sprint.check"] || [], "test --warnings-as-errors")
  end
end
