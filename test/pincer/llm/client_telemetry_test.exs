defmodule Pincer.LLM.ClientTelemetryTest do
  use ExUnit.Case, async: false

  alias Pincer.LLM.Client
  alias Pincer.Test.Support.LLMHelpers

  defmodule TelemetryAdapter do
    use Pincer.Test.Support.LLMProviderDefaults

    @impl true
    def chat_completion(_messages, _model, config, _tools) do
      call_number = Process.get(:client_telemetry_call, 0) + 1
      Process.put(:client_telemetry_call, call_number)

      case {config[:scenario], call_number} do
        {:always_timeout, _} ->
          {:error, %Req.TransportError{reason: :timeout}}

        {:once_503_then_ok, 1} ->
          {:error, {:http_error, 503, "upstream"}}

        _ ->
          {:ok, %{"role" => "assistant", "content" => "ok"}, nil}
      end
    end

    @impl true
    def stream_completion(messages, model, config, tools) do
      case chat_completion(messages, model, config, tools) do
        {:ok, _, _} -> {:ok, [%{"choices" => [%{"delta" => %{"content" => "ok"}}]}]}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  setup do
    handler_id = "pincer-client-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:pincer, :error], [:pincer, :retry]],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    LLMHelpers.put_default_provider!("telemetry_provider")
    LLMHelpers.put_app_env!(:llm_retry, Application.get_env(:pincer, :llm_retry))

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    :ok
  end

  test "emits error telemetry on terminal failure" do
    Process.delete(:client_telemetry_call)

    LLMHelpers.put_providers!(%{
      "telemetry_provider" => %{
        adapter: TelemetryAdapter,
        default_model: "test-model",
        scenario: :always_timeout
      }
    })

    Application.put_env(:pincer, :llm_retry,
      max_retries: 0,
      initial_backoff: 1,
      max_backoff: 1,
      jitter_ratio: 0.0,
      max_elapsed_ms: 100
    )

    assert {:error, {:transport_error, :timeout}} = Client.chat_completion([])

    assert_receive {:telemetry, [:pincer, :error], %{count: 1}, metadata}
    assert metadata.class == :transport_timeout
    assert metadata.action == :chat_completion
  end

  test "emits retry telemetry on transient failure before success" do
    Process.delete(:client_telemetry_call)

    LLMHelpers.put_providers!(%{
      "telemetry_provider" => %{
        adapter: TelemetryAdapter,
        default_model: "test-model",
        scenario: :once_503_then_ok
      }
    })

    Application.put_env(:pincer, :llm_retry,
      max_retries: 1,
      initial_backoff: 1,
      max_backoff: 1,
      jitter_ratio: 0.0,
      max_elapsed_ms: 100
    )

    assert {:ok, %{"content" => "ok"}, _usage} = Client.chat_completion([])

    assert_receive {:telemetry, [:pincer, :retry], %{count: 1, wait_ms: 1}, metadata}
    assert metadata.class == :http_5xx
    assert metadata.action == :chat_completion
  end
end
