defmodule Pincer.LLM.RetryPolicyTest do
  use ExUnit.Case, async: false

  alias Pincer.LLM.Client
  alias Pincer.Test.Support.LLMHelpers

  defmodule RetryAdapter do
    use Pincer.Test.Support.LLMProviderDefaults

    @impl true
    def chat_completion(_messages, _model, config, _tools) do
      call_number = Process.get(:retry_policy_call_number, 0) + 1
      Process.put(:retry_policy_call_number, call_number)
      send(self(), {:retry_policy_call, config[:scenario], call_number})

      case {config[:scenario], call_number} do
        {:provider_error, _} ->
          {:error, {:provider_error, 400, "Provider returned error"}}

        {:http_400, _} ->
          {:error, {:http_error, 400, "bad request"}}

        {:http_503_then_ok, 1} ->
          {:error, {:http_error, 503, "upstream"}}

        {:always_503, _} ->
          {:error, {:http_error, 503, "upstream"}}

        {:http_401, _} ->
          {:error, {:http_error, 401, "unauthorized"}}

        {:transport_timeout_then_ok, 1} ->
          {:error, %Req.TransportError{reason: :timeout}}

        {:retry_after_then_ok, 1} ->
          {:error, {:http_error, 429, "rate", %{retry_after_ms: 60}}}

        {:retry_after_date_then_ok, 1} ->
          now = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

          # HTTP-date has second precision; keep enough headroom to avoid sub-second truncation flakiness.
          target_dt = DateTime.from_unix!(now + 2200, :millisecond)
          retry_after = Calendar.strftime(target_dt, "%a, %d %b %Y %H:%M:%S GMT")
          {:error, {:http_error, 429, "rate", %{retry_after: retry_after}}}

        _ ->
          {:ok, %{"role" => "assistant", "content" => "ok"}, nil}
      end
    end

    @impl true
    def stream_completion(messages, model, config, tools) do
      case chat_completion(messages, model, config, tools) do
        {:ok, _, _} -> {:ok, [%{"choices" => [%{"delta" => %{"content" => "stream-ok"}}]}]}
        error -> error
      end
    end

    @impl true
    def list_models(_config), do: {:ok, []}

    @impl true
    def transcribe_audio(_path, _model, _config), do: {:ok, "mock transcript"}
  end

  setup do
    LLMHelpers.put_default_provider!("retry_provider")

    LLMHelpers.put_app_env!(
      :llm_retry,
      max_retries: 2,
      initial_backoff: 5,
      max_backoff: 30,
      max_elapsed_ms: 3_000,
      jitter_ratio: 0.0
    )

    :ok
  end

  test "retries transient HTTP 503 and succeeds" do
    put_provider_scenario(:http_503_then_ok)

    assert {:ok, %{"content" => "ok"}, _usage} = Client.chat_completion([])

    assert_received {:retry_policy_call, :http_503_then_ok, 1}
    assert_received {:retry_policy_call, :http_503_then_ok, 2}
    refute_received {:retry_policy_call, :http_503_then_ok, 3}
  end

  test "does not retry non-retryable HTTP 401" do
    put_provider_scenario(:http_401)

    assert {:error, {:http_error, 401, _}} = Client.chat_completion([])

    assert_received {:retry_policy_call, :http_401, 1}
    refute_received {:retry_policy_call, :http_401, 2}
  end

  test "fails fast on provider payload errors without failover status noise" do
    put_provider_scenario(:provider_error)
    Process.put(:session_pid, self())

    on_exit(fn ->
      Process.delete(:session_pid)
    end)

    assert {:error, {:provider_error, 400, "Provider returned error"}} =
             Client.chat_completion([])

    assert_received {:retry_policy_call, :provider_error, 1}
    refute_received {:retry_policy_call, :provider_error, 2}
    refute_receive {:llm_runtime_status, %{kind: :failover}}, 200
  end

  test "handles terminal HTTP 400 without crashing when retry/cooldown configs are malformed lists" do
    LLMHelpers.put_system_env!("TEST_RETRY_AUTH_PRIMARY", "test-auth-key")

    LLMHelpers.put_providers!(%{
      "retry_provider" => %{
        adapter: RetryAdapter,
        default_model: "retry-model",
        scenario: :http_400,
        auth_profiles: [%{name: "primary", env_key: "TEST_RETRY_AUTH_PRIMARY"}]
      }
    })

    LLMHelpers.put_app_env!(:llm_retry, [%{"max_retries" => 0}])
    LLMHelpers.put_app_env!(:llm_cooldown, [%{"durations_ms" => %{"http_400" => 1_000}}])

    LLMHelpers.put_app_env!(:auth_profile_cooldown, [
      %{"durations_ms" => %{"http_400" => 1_000}}
    ])

    assert {:error, {:http_error, 400, "bad request"}} =
             Client.chat_completion([], provider: "retry_provider")

    assert_received {:retry_policy_call, :http_400, 1}
    refute_received {:retry_policy_call, :http_400, 2}
  end

  test "retries transient transport timeout and succeeds" do
    put_provider_scenario(:transport_timeout_then_ok)

    assert {:ok, %{"content" => "ok"}, _usage} = Client.chat_completion([])

    assert_received {:retry_policy_call, :transport_timeout_then_ok, 1}
    assert_received {:retry_policy_call, :transport_timeout_then_ok, 2}
  end

  test "emits runtime status payload while waiting retry backoff" do
    put_provider_scenario(:http_503_then_ok)
    Process.put(:session_pid, self())

    on_exit(fn ->
      Process.delete(:session_pid)
    end)

    assert {:ok, %{"content" => "ok"}, _usage} = Client.chat_completion([])

    assert_receive {:llm_runtime_status, status}, 1000
    assert status.kind == :retry_wait
    assert status.reason == "HTTP 503"
    assert is_integer(status.wait_ms)
    assert status.retries_left >= 1
  end

  test "emits runtime failover status when retry budget is exhausted" do
    put_provider_scenario(:always_503)
    Process.put(:session_pid, self())

    on_exit(fn ->
      Process.delete(:session_pid)
    end)

    Application.put_env(:pincer, :llm_retry,
      max_retries: 1,
      initial_backoff: 1,
      max_backoff: 1,
      max_elapsed_ms: 2_000,
      jitter_ratio: 0.0
    )

    assert {:error, {:http_error, 503, _}} = Client.chat_completion([])

    statuses = collect_runtime_statuses([], 1_500)

    assert Enum.any?(statuses, fn status ->
             status.kind == :failover and status.failover_action == :stop and
               status.reason == "HTTP 503"
           end)
  end

  test "respects retry_after delay when provided" do
    put_provider_scenario(:retry_after_then_ok)

    started_at = System.monotonic_time(:millisecond)
    assert {:ok, %{"content" => "ok"}, _usage} = Client.chat_completion([])
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert_received {:retry_policy_call, :retry_after_then_ok, 1}
    assert_received {:retry_policy_call, :retry_after_then_ok, 2}
    assert elapsed >= 50
  end

  test "applies retry policy to stream completion" do
    put_provider_scenario(:http_503_then_ok)

    assert {:ok, chunks} = Client.stream_completion([])
    assert Enum.count(chunks) == 1

    assert_received {:retry_policy_call, :http_503_then_ok, 1}
    assert_received {:retry_policy_call, :http_503_then_ok, 2}
  end

  test "stops retrying when max elapsed would be exceeded" do
    put_provider_scenario(:always_503)

    Application.put_env(:pincer, :llm_retry,
      max_retries: 10,
      initial_backoff: 20,
      max_backoff: 20,
      max_elapsed_ms: 25,
      jitter_ratio: 0.0
    )

    assert {:error, {:retry_timeout, {:http_error, 503, _}}} = Client.chat_completion([])

    assert_received {:retry_policy_call, :always_503, 1}
    assert_received {:retry_policy_call, :always_503, 2}
    refute_received {:retry_policy_call, :always_503, 3}
  end

  test "parses Retry-After HTTP-date" do
    now_ms = 1_700_000_000_000
    retry_after = "Tue, 14 Nov 2023 22:13:21 GMT"

    assert 1_000 == Client.parse_retry_after(retry_after, now_ms)
  end

  test "retries using Retry-After date metadata" do
    put_provider_scenario(:retry_after_date_then_ok)

    started_at = System.monotonic_time(:millisecond)
    assert {:ok, %{"content" => "ok"}, _usage} = Client.chat_completion([])
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert_received {:retry_policy_call, :retry_after_date_then_ok, 1}
    assert_received {:retry_policy_call, :retry_after_date_then_ok, 2}
    assert elapsed >= 900
  end

  defp put_provider_scenario(scenario) do
    Process.delete(:retry_policy_call_number)

    LLMHelpers.put_providers!(%{
      "retry_provider" => %{
        adapter: RetryAdapter,
        default_model: "retry-model",
        scenario: scenario
      }
    })
  end

  defp collect_runtime_statuses(acc, timeout_ms) when timeout_ms <= 0, do: Enum.reverse(acc)

  defp collect_runtime_statuses(acc, timeout_ms) do
    receive do
      {:llm_runtime_status, status} ->
        collect_runtime_statuses([status | acc], timeout_ms)
    after
      timeout_ms ->
        Enum.reverse(acc)
    end
  end
end
