defmodule Pincer.Ports.LLMTest do
  use ExUnit.Case, async: false

  alias Pincer.Ports.LLM

  defmodule Adapter do
    def chat_completion(history, opts), do: {:ok, {history, opts}, nil}
    def list_providers, do: [%{id: "legacy-test"}]
  end

  test "the legacy port keeps the shared port's functions and callbacks" do
    assert Pincer.Ports.LLM.__info__(:functions) ==
             PincerPorts.LLM.__info__(:functions)

    assert Pincer.Ports.LLM.behaviour_info(:callbacks) ==
             PincerPorts.LLM.behaviour_info(:callbacks)

    assert {:generate_embedding, 2} in Pincer.Ports.LLM.behaviour_info(:callbacks)
    assert {:generate_embedding, 2} in PincerPorts.LLM.behaviour_info(:callbacks)
    refute {:generate_embedding, 2} in Pincer.Ports.LLM.behaviour_info(:optional_callbacks)
    refute {:generate_embedding, 2} in PincerPorts.LLM.behaviour_info(:optional_callbacks)
  end

  test "the legacy port dispatches with the completion defaults" do
    previous = Application.fetch_env(:pincer, :llm_adapter)
    Application.put_env(:pincer, :llm_adapter, Adapter)

    on_exit(fn ->
      case previous do
        {:ok, adapter} -> Application.put_env(:pincer, :llm_adapter, adapter)
        :error -> Application.delete_env(:pincer, :llm_adapter)
      end
    end)

    history = [%{role: "user", content: "Hello"}]

    assert LLM.chat_completion(history) == {:ok, {history, []}, nil}
    assert LLM.list_providers() == [%{id: "legacy-test"}]
  end
end
