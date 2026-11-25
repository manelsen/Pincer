defmodule Pincer.Architecture.CoreExternalErrorsTest do
  use ExUnit.Case, async: true

  test "Core does not reference Req or Exqlite modules or structs" do
    pattern = ~r/\b(?:Req|Exqlite)\./

    offenders =
      for file <- Path.wildcard("lib/pincer/core/**/*.ex"),
          File.read!(file) =~ pattern,
          do: file

    assert offenders == []
  end
end
