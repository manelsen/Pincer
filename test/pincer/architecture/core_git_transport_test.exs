defmodule Pincer.Architecture.CoreGitTransportTest do
  use ExUnit.Case, async: true

  test "Core Git operations avoid direct process and HTTP calls" do
    transport_calls = ~r{\bSystem\.cmd\(\s*"git"|\bReq\.get\(}

    offenders =
      for file <- Path.wildcard("lib/pincer/core/**/*.ex"),
          File.read!(file) =~ transport_calls,
          do: file

    assert offenders == []
  end

  test "the legacy GitHub watcher is absent from the application" do
    refute Code.ensure_loaded?(Pincer.Core.Heartbeat.GitHubWatcher)
    refute File.read!("lib/pincer/application.ex") =~ "GitHubWatcher"
  end
end
