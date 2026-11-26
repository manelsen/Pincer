defmodule Pincer.Core.Project.PlannerTest do
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Core.Project.Planner
  alias Pincer.Test.Support.LLMHelpers

  setup :set_mox_from_context

  setup do
    LLMHelpers.put_providers!(
      %{"test" => LLMHelpers.mock_provider_config()},
      default: "test"
    )

    :ok
  end

  test "build_plan/1 decomposes objective into tasks via LLM" do
    Pincer.LLM.ClientMock
    |> expect(:chat_completion, fn _msgs, _model, _config, _tools ->
      {:ok, %{"content" => "Architect: Spec\nTester: Red\nCoder: Green\nTester: Refactor"}, nil}
    end)

    assert {:ok, tasks} = Planner.build_plan("Test Project")
    assert length(tasks) == 4
  end

  test "build_plan/1 returns error on LLM failure" do
    Pincer.LLM.ClientMock
    |> expect(:chat_completion, fn _msgs, _model, _config, _tools -> {:error, :timeout} end)

    assert {:error, :timeout} = Planner.build_plan("Fail Project")
  end
end
