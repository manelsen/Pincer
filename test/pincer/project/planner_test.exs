defmodule Pincer.Core.Project.PlannerTest do
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Core.Project.Planner

  setup :set_mox_from_context

  setup do
    original_providers = Application.get_env(:pincer, :llm_providers)
    original_default = Application.get_env(:pincer, :default_llm_provider)

    Application.put_env(:pincer, :llm_providers, %{
      "test" => %{
        adapter: Pincer.LLM.ClientMock,
        base_url: "http://mock",
        default_model: "test-model",
        env_key: "MOCK_KEY"
      }
    })

    Application.put_env(:pincer, :default_llm_provider, "test")

    on_exit(fn ->
      if is_nil(original_providers) do
        Application.delete_env(:pincer, :llm_providers)
      else
        Application.put_env(:pincer, :llm_providers, original_providers)
      end

      if is_nil(original_default) do
        Application.delete_env(:pincer, :default_llm_provider)
      else
        Application.put_env(:pincer, :default_llm_provider, original_default)
      end
    end)

    :ok
  end

  test "build_plan/1 decomposes objective into tasks via LLM" do
    Pincer.LLM.ClientMock
    |> expect(:chat_completion, fn _msgs, _model, _config, _tools ->
      {:ok, %{"content" => "Architect: Spec\nTester: Red\nCoder: Green\nTester: Refactor"}}
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
