defmodule Pincer.Architecture.DeadCoreModulesRemovedTest do
  use ExUnit.Case, async: true

  @dead_modules [
    {Pincer.Core.LLM.ModelRouter, "lib/pincer/core/llm/model_router.ex",
     "Pincer.Core.LLM.ModelRouter"},
    {Pincer.Core.Session.CommandQueue, "lib/pincer/core/session/command_queue.ex",
     "Pincer.Core.Session.CommandQueue"},
    {Pincer.Core.Heartbeat.ContractEngine, "lib/pincer/core/heartbeat/contract_engine.ex",
     "Pincer.Core.Heartbeat.ContractEngine"},
    {Pincer.Core.ReleaseValidation, "lib/pincer/core/release_validation.ex",
     "Pincer.Core.ReleaseValidation"},
    {Pincer.Core.ProjectBoard, "lib/pincer/core/project_board.ex", "Pincer.Core.ProjectBoard"},
    {Pincer.Core.Capabilities, "lib/pincer/core/capabilities.ex", "Pincer.Core.Capabilities"},
    {Pincer.Core.Orchestration.Scheduler, "lib/pincer/core/orchestration/scheduler.ex",
     "Pincer.Core.Orchestration.Scheduler"}
  ]

  test "dead core module source files do not exist on disk" do
    existing =
      for {_mod, path, _name} <- @dead_modules,
          File.exists?(path),
          do: path

    assert existing == []
    refute File.dir?("lib/pincer/core/heartbeat")
  end

  test "dead core modules are not loadable" do
    loaded =
      for {mod, _path, _name} <- @dead_modules,
          Code.ensure_loaded?(mod),
          do: mod

    assert loaded == []
  end

  test "no .ex or .exs file in lib/ or packages/ references dead core module names" do
    files =
      Path.wildcard("lib/**/*.{ex,exs}") ++
        Path.wildcard("packages/**/*.{ex,exs}")

    names = Enum.map(@dead_modules, fn {_mod, _path, name} -> name end)

    references =
      for file <- files,
          content = File.read!(file),
          name <- names,
          String.contains?(content, name),
          do: {file, name}

    assert references == []
  end
end
