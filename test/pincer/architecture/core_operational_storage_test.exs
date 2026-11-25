defmodule Pincer.Architecture.CoreOperationalStorageTest do
  use ExUnit.Case, async: true

  test "Core delegates operational persistence without invoking database queries" do
    database_calls = ~r{\bSQLite\.(query|execute|transaction)\(}

    offenders =
      for file <- Path.wildcard("lib/pincer/core/**/*.ex"),
          File.read!(file) =~ database_calls,
          do: file

    assert offenders == []
  end
end
