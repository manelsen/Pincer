defmodule Pincer.Architecture.BoundaryMixConfigTest do
  @moduledoc """
  Guards `mix.exs` against dead Boundary configuration options ignored in Boundary 0.12.0.
  """

  use ExUnit.Case, async: true

  test "does not configure dead :externals option under :boundary" do
    config = boundary_config()

    refute Keyword.has_key?(config, :externals),
           "Expected Pincer.MixProject.project()[:boundary] not to include :externals, got: #{inspect(config)}"
  end

  test "does not configure dead :ignore_unknown option under :boundary" do
    config = boundary_config()

    refute Keyword.has_key?(config, :ignore_unknown),
           "Expected Pincer.MixProject.project()[:boundary] not to include :ignore_unknown, got: #{inspect(config)}"
  end

  defp boundary_config do
    config = Pincer.MixProject.project()[:boundary] || []
    assert Keyword.keyword?(config)
    config
  end
end
