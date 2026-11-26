defmodule Pincer.Core.Session.ServerDecompositionTest do
  use ExUnit.Case, async: true

  @extracted_modules [
    {Pincer.Core.Session.TaskCoordinator, "lib/pincer/core/session/task_coordinator.ex"},
    {Pincer.Core.Session.BlackboardIngestor, "lib/pincer/core/session/blackboard_ingestor.ex"},
    {Pincer.Core.Session.InputBuffer, "lib/pincer/core/session/input_buffer.ex"},
    {Pincer.Core.Session.CommandDispatcher, "lib/pincer/core/session/command_dispatcher.ex"}
  ]

  test "Session.Server is decomposed under 400 LOC and delegates to extracted modules" do
    source = File.read!("lib/pincer/core/session/server.ex")
    loc = source |> String.split("\n") |> length()

    assert loc < 400, "Expected lib/pincer/core/session/server.ex to be < 400 LOC, got #{loc}"

    for {mod, path} <- @extracted_modules do
      assert File.exists?(path), "Expected #{path} to exist"
      assert Code.ensure_loaded?(mod), "Expected #{inspect(mod)} to be loaded"
      short_name = mod |> Module.split() |> List.last()
      assert source =~ short_name
    end
  end

  test "Session boundary keeps extracted internal modules unexported" do
    [%{opts: opts}] = Pincer.Core.Session.__info__(:attributes)[Boundary]
    exports = Enum.map(opts[:exports], &Module.concat(Pincer.Core.Session, &1))

    for {mod, _path} <- @extracted_modules do
      refute mod in exports
    end
  end
end
