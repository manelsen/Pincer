defmodule Pincer.LLM.ReactiveClientTest do
  use ExUnit.Case, async: false

  alias Pincer.LLM.Client
  alias Pincer.Test.Support.LLMHelpers

  defmodule ReactiveMockAdapter do
    use Pincer.Test.Support.LLMProviderDefaults

    @impl true
    def chat_completion(_messages, _model, config, _tools) do
      case config[:scenario] do
        :fail_once ->
          if Process.get(:fail_count, 0) == 0 do
            Process.put(:fail_count, 1)
            notify_attempt(config)
            {:error, {:http_error, 429, "Rate limited"}}
          else
            {:ok, %{"role" => "assistant", "content" => "Success after retry"}, nil}
          end

        :always_fail ->
          notify_attempt(config)
          {:error, {:http_error, 429, "Rate limited"}}

        :success ->
          {:ok, %{"role" => "assistant", "content" => "Success with #{config[:name]}"}, nil}
      end
    end

    @impl true
    def stream_completion(_messages, _model, _config, _tools) do
      {:ok, [%{"choices" => [%{"delta" => %{"content" => "stream"}}]}]}
    end

    defp notify_attempt(config) do
      if pid = config[:notify_pid], do: send(pid, :reactive_attempt_failed)
    end
  end

  setup do
    test_pid = self()

    LLMHelpers.put_providers!(%{
      "p1" => %{
        adapter: ReactiveMockAdapter,
        scenario: :always_fail,
        name: "Provider 1",
        env_key: "K1",
        notify_pid: test_pid
      },
      "p2" => %{
        adapter: ReactiveMockAdapter,
        scenario: :success,
        name: "Provider 2",
        env_key: "K2"
      }
    })

    LLMHelpers.put_system_env!("K1", "v1")
    LLMHelpers.put_system_env!("K2", "v2")

    :ok
  end

  test "instant retry when model changed during backoff" do
    # Start a request that will fail and enter backoff
    task =
      Task.async(fn ->
        Client.chat_completion([], provider: "p1")
      end)

    assert_receive :reactive_attempt_failed, 1_000

    # Now change the model by sending a message to the task process
    send(task.pid, {:model_changed, "p2", "default-model"})

    # The task should now return result from p2 almost immediately
    # (instead of waiting for the initial 2s backoff)
    result = Task.await(task, 1000)

    assert {:ok, %{"content" => "Success with Provider 2"}, _usage} = result
  end

  test "concurrent model changes during backoff apply the latest selection" do
    LLMHelpers.put_provider!("p3", %{
      adapter: ReactiveMockAdapter,
      scenario: :success,
      name: "Provider 3",
      env_key: "K3"
    })

    LLMHelpers.put_system_env!("K3", "v3")

    task =
      Task.async(fn ->
        Client.chat_completion([], provider: "p1")
      end)

    assert_receive :reactive_attempt_failed, 1_000
    send(task.pid, {:model_changed, "p2", "default-model"})
    send(task.pid, {:model_changed, "p3", "default-model"})

    result = Task.await(task, 1000)

    assert {:ok, %{"content" => "Success with Provider 3"}, _usage} = result
  end
end
