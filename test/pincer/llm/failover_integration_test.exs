defmodule Pincer.LLM.FailoverIntegrationTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.LLM.CooldownStore
  alias Pincer.LLM.Client

  defmodule FailoverAdapter do
    use Pincer.Test.Support.LLMProviderDefaults

    @impl true
    def chat_completion(_messages, model, config, _tools) do
      provider_id = config[:provider_id]
      send(self(), {:failover_attempt, provider_id, model})

      case {provider_id, model, config[:scenario]} do
        {"p1", "m1", :chain_to_provider} ->
          {:error, {:http_error, 429, "rate"}}

        {"p1", "m2", :chain_to_provider} ->
          {:error, {:http_error, 503, "upstream"}}

        {"p2", "x1", :chain_to_provider} ->
          {:ok, %{"role" => "assistant", "content" => "ok:p2:x1"}, nil}

        {"p1", "m1", :terminal_401} ->
          {:error, {:http_error, 401, "unauthorized"}}

        _ ->
          {:error, {:http_error, 500, "unexpected"}}
      end
    end

    @impl true
    def stream_completion(messages, model, config, tools) do
      case chat_completion(messages, model, config, tools) do
        {:ok, %{"content" => content}, _usage} ->
          {:ok, [%{"choices" => [%{"delta" => %{"content" => content}}]}]}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defmodule StreamParityAdapter do
    use Pincer.Test.Support.LLMProviderDefaults

    @impl true
    def chat_completion(_messages, model, config, _tools) do
      provider_id = config[:provider_id]
      send(self(), {:stream_failover_attempt, :chat, provider_id, model})

      case {provider_id, model, config[:scenario]} do
        {"p2", "x1", :stream_chain_to_provider} ->
          {:ok, %{"role" => "assistant", "content" => "chat-ok:p2:x1"}, nil}

        {_, _, :stream_chain_to_provider} ->
          {:error, {:http_error, 500, "chat path should not be used"}}

        _ ->
          {:error, {:http_error, 500, "unexpected"}}
      end
    end

    @impl true
    def stream_completion(_messages, model, config, _tools) do
      provider_id = config[:provider_id]
      send(self(), {:stream_failover_attempt, :stream, provider_id, model})

      case {provider_id, model, config[:scenario]} do
        {"p1", "m1", :stream_chain_to_provider} ->
          {:error, {:http_error, 429, "rate"}}

        {"p1", "m2", :stream_chain_to_provider} ->
          {:error, {:http_error, 503, "upstream"}}

        {"p2", "x1", :stream_chain_to_provider} ->
          {:ok, [%{"choices" => [%{"delta" => %{"content" => "ok-stream:p2:x1"}}]}]}

        _ ->
          {:error, {:http_error, 500, "unexpected"}}
      end
    end
  end

  setup do
    original_providers = Application.get_env(:pincer, :llm_providers)
    original_default = Application.get_env(:pincer, :default_llm_provider)
    original_retry = Application.get_env(:pincer, :llm_retry)
    original_cooldown = Application.get_env(:pincer, :llm_cooldown)

    CooldownStore.reset()

    Application.put_env(:pincer, :default_llm_provider, "p1")

    Application.put_env(:pincer, :llm_retry,
      max_retries: 0,
      initial_backoff: 1,
      max_backoff: 1,
      max_elapsed_ms: 5_000,
      jitter_ratio: 0.0
    )

    on_exit(fn ->
      if original_providers do
        Application.put_env(:pincer, :llm_providers, original_providers)
      else
        Application.delete_env(:pincer, :llm_providers)
      end

      if original_default do
        Application.put_env(:pincer, :default_llm_provider, original_default)
      else
        Application.delete_env(:pincer, :default_llm_provider)
      end

      if original_retry do
        Application.put_env(:pincer, :llm_retry, original_retry)
      else
        Application.delete_env(:pincer, :llm_retry)
      end

      if original_cooldown do
        Application.put_env(:pincer, :llm_cooldown, original_cooldown)
      else
        Application.delete_env(:pincer, :llm_cooldown)
      end

      CooldownStore.reset()
    end)

    :ok
  end

  test "falls back deterministically model->provider for retryable errors" do
    Application.put_env(:pincer, :llm_providers, %{
      "p1" => %{
        adapter: FailoverAdapter,
        provider_id: "p1",
        default_model: "m1",
        models: ["m1", "m2"],
        scenario: :chain_to_provider
      },
      "p2" => %{
        adapter: FailoverAdapter,
        provider_id: "p2",
        default_model: "x1",
        models: ["x1"],
        scenario: :chain_to_provider
      }
    })

    assert {:ok, %{"content" => "ok:p2:x1"}, _usage} = Client.chat_completion([], provider: "p1")

    assert_received {:failover_attempt, "p1", "m1"}
    assert_received {:failover_attempt, "p1", "m2"}
    assert_received {:failover_attempt, "p2", "x1"}
  end

  test "stops immediately for terminal class without fallback" do
    Application.put_env(:pincer, :llm_providers, %{
      "p1" => %{
        adapter: FailoverAdapter,
        provider_id: "p1",
        default_model: "m1",
        models: ["m1", "m2"],
        scenario: :terminal_401
      },
      "p2" => %{
        adapter: FailoverAdapter,
        provider_id: "p2",
        default_model: "x1",
        models: ["x1"],
        scenario: :terminal_401
      }
    })

    assert {:error, {:http_error, 401, "unauthorized"}} =
             Client.chat_completion([], provider: "p1")

    assert_received {:failover_attempt, "p1", "m1"}
    refute_received {:failover_attempt, "p1", "m2"}
    refute_received {:failover_attempt, "p2", "x1"}
  end

  test "default provider on cooldown is bypassed on next request" do
    Application.put_env(:pincer, :llm_cooldown,
      durations_ms: %{
        http_429: 5_000,
        http_5xx: 5_000
      }
    )

    Application.put_env(:pincer, :llm_providers, %{
      "p1" => %{
        adapter: FailoverAdapter,
        provider_id: "p1",
        default_model: "m1",
        models: ["m1", "m2"],
        scenario: :chain_to_provider
      },
      "p2" => %{
        adapter: FailoverAdapter,
        provider_id: "p2",
        default_model: "x1",
        models: ["x1"],
        scenario: :chain_to_provider
      }
    })

    assert {:ok, %{"content" => "ok:p2:x1"}, _usage} = Client.chat_completion([])

    assert_received {:failover_attempt, "p1", "m1"}
    assert_received {:failover_attempt, "p1", "m2"}
    assert_received {:failover_attempt, "p2", "x1"}

    flush_failover_attempts()

    assert {:ok, %{"content" => "ok:p2:x1"}, _usage} = Client.chat_completion([])

    # Second request should start directly on p2 because p1 is cooling down.
    assert_received {:failover_attempt, "p2", "x1"}
    refute_received {:failover_attempt, "p1", "m1"}
  end

  test "stream path follows deterministic failover chain without dropping to chat path" do
    Application.put_env(:pincer, :llm_providers, %{
      "p1" => %{
        adapter: StreamParityAdapter,
        provider_id: "p1",
        default_model: "m1",
        models: ["m1", "m2"],
        scenario: :stream_chain_to_provider
      },
      "p2" => %{
        adapter: StreamParityAdapter,
        provider_id: "p2",
        default_model: "x1",
        models: ["x1"],
        scenario: :stream_chain_to_provider
      }
    })

    assert {:ok, stream} = Client.stream_completion([], provider: "p1")

    assert Enum.any?(Enum.to_list(stream), fn chunk ->
             get_in(chunk, ["choices", Access.at(0), "delta", "content"]) == "ok-stream:p2:x1"
           end)

    assert_received {:stream_failover_attempt, :stream, "p1", "m1"}
    assert_received {:stream_failover_attempt, :stream, "p1", "m2"}
    assert_received {:stream_failover_attempt, :stream, "p2", "x1"}
    refute_received {:stream_failover_attempt, :chat, _, _}
  end

  test "stream request bypasses cooling-down default provider on next request" do
    Application.put_env(:pincer, :llm_cooldown,
      durations_ms: %{
        http_429: 5_000,
        http_5xx: 5_000
      }
    )

    Application.put_env(:pincer, :llm_providers, %{
      "p1" => %{
        adapter: StreamParityAdapter,
        provider_id: "p1",
        default_model: "m1",
        models: ["m1", "m2"],
        scenario: :stream_chain_to_provider
      },
      "p2" => %{
        adapter: StreamParityAdapter,
        provider_id: "p2",
        default_model: "x1",
        models: ["x1"],
        scenario: :stream_chain_to_provider
      }
    })

    assert {:ok, stream1} = Client.stream_completion([])
    assert Enum.to_list(stream1) != []

    assert_received {:stream_failover_attempt, :stream, "p1", "m1"}
    assert_received {:stream_failover_attempt, :stream, "p1", "m2"}
    assert_received {:stream_failover_attempt, :stream, "p2", "x1"}

    flush_stream_failover_attempts()

    assert {:ok, stream2} = Client.stream_completion([])
    assert Enum.to_list(stream2) != []

    assert_received {:stream_failover_attempt, :stream, "p2", "x1"}
    refute_received {:stream_failover_attempt, :stream, "p1", "m1"}
    refute_received {:stream_failover_attempt, :chat, _, _}
  end

  defp flush_failover_attempts do
    receive do
      {:failover_attempt, _, _} -> flush_failover_attempts()
    after
      0 -> :ok
    end
  end

  defp flush_stream_failover_attempts do
    receive do
      {:stream_failover_attempt, _, _, _} -> flush_stream_failover_attempts()
    after
      0 -> :ok
    end
  end
end
