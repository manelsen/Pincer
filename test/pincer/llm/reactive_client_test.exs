defmodule Pincer.LLM.ReactiveClientTest do
  use ExUnit.Case, async: false

  alias Pincer.LLM.Client

  defmodule ReactiveMockAdapter do
    @behaviour Pincer.LLM.Provider

    @impl true
    def chat_completion(_messages, _model, config, _tools) do
      # Small delay to simulate network
      Process.sleep(50)

      case config[:scenario] do
        :fail_once ->
          if Process.get(:fail_count, 0) == 0 do
            Process.put(:fail_count, 1)
            {:error, {:http_error, 429, "Rate limited"}}
          else
            {:ok, %{"role" => "assistant", "content" => "Success after retry"}, nil}
          end

        :always_fail ->
          {:error, {:http_error, 429, "Rate limited"}}

        :success ->
          {:ok, %{"role" => "assistant", "content" => "Success with #{config[:name]}"}, nil}
      end
    end

    @impl true
    def stream_completion(_messages, _model, _config, _tools) do
      {:ok, [%{"choices" => [%{"delta" => %{"content" => "stream"}}]}]}
    end
  end

  setup do
    orig_providers = Application.get_env(:pincer, :llm_providers)

    Application.put_env(:pincer, :llm_providers, %{
      "p1" => %{
        adapter: ReactiveMockAdapter,
        scenario: :always_fail,
        name: "Provider 1",
        env_key: "K1"
      },
      "p2" => %{
        adapter: ReactiveMockAdapter,
        scenario: :success,
        name: "Provider 2",
        env_key: "K2"
      }
    })

    System.put_env("K1", "v1")
    System.put_env("K2", "v2")

    on_exit(fn ->
      Application.put_env(:pincer, :llm_providers, orig_providers)
    end)

    :ok
  end

  test "instant retry when model changed during backoff" do
    # Start a request that will fail and enter backoff
    task =
      Task.async(fn ->
        Client.chat_completion([], provider: "p1")
      end)

    # Wait for it to fail once (we need a way to know it entered sleep)
    # Since we use receive-based sleep, we can send a message to it.
    # But wait, how do we find the process? Task.async gives us the pid in task.pid.

    # Give it time to hit the first 429
    Process.sleep(100)

    # Now change the model by sending a message to the task process
    send(task.pid, {:model_changed, "p2", "default-model"})

    # The task should now return result from p2 almost immediately 
    # (instead of waiting for the initial 2s backoff)
    result = Task.await(task, 1000)

    assert {:ok, %{"content" => "Success with Provider 2"}, _usage} = result
  end

  test "concurrent model changes during backoff apply the latest selection" do
    providers = Application.get_env(:pincer, :llm_providers, %{})

    Application.put_env(
      :pincer,
      :llm_providers,
      Map.put(providers, "p3", %{
        adapter: ReactiveMockAdapter,
        scenario: :success,
        name: "Provider 3",
        env_key: "K3"
      })
    )

    System.put_env("K3", "v3")

    task =
      Task.async(fn ->
        Client.chat_completion([], provider: "p1")
      end)

    Process.sleep(100)
    send(task.pid, {:model_changed, "p2", "default-model"})
    send(task.pid, {:model_changed, "p3", "default-model"})

    result = Task.await(task, 1000)

    assert {:ok, %{"content" => "Success with Provider 3"}, _usage} = result
  end
end
