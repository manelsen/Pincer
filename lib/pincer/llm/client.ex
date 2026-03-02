defmodule Pincer.LLM.Client do
  @moduledoc """
  A unified HTTP client for multiple LLM providers using the Adapter Pattern.

  This module serves as a dispatcher. It looks up the configured provider
  in the application environment, instantiates the proper adapter
  (e.g., `Pincer.LLM.Providers.OpenAICompat`), and delegates the call.

  ## Configuration

  Configure providers in your `config/config.exs`:

      config :pincer, :llm_providers, %{
        "openrouter" => %{
          adapter: Pincer.LLM.Providers.OpenAICompat,
          base_url: "https://openrouter.ai/api/v1/chat/completions",
          default_model: "openrouter/free",
          env_key: "OPENROUTER_API_KEY",
          headers: [{"HTTP-Referer", "https://github.com/Pincer/pincer"}, {"X-Title", "Pincer"}]
        }
      }

  ## Examples

      iex> Pincer.LLM.Client.chat_completion([
      ...>   %{"role" => "user", "content" => "Hello!"}
      ...> ], provider: "openrouter")
      {:ok, %{"role" => "assistant", "content" => "Hello! How can I help you?"}}
  """

  @behaviour Pincer.Core.Ports.LLM
  require Logger
  alias Pincer.Core.AuthProfiles
  alias Pincer.Core.LLM.CooldownStore
  alias Pincer.Core.LLM.FailoverPolicy
  alias Pincer.Core.Models.Registry, as: ModelRegistry
  alias Pincer.Core.RetryPolicy
  alias Pincer.Core.Telemetry, as: CoreTelemetry

  @default_max_retries 5
  @default_initial_backoff 2000
  @default_max_backoff 30_000
  @default_jitter_ratio 0.20
  @default_max_elapsed_ms 120_000

  @type message :: Pincer.LLM.Provider.message()
  @type tool :: Pincer.LLM.Provider.tool()
  @type chat_result :: Pincer.LLM.Provider.chat_result()

  @doc """
  Sends a chat completion request to the configured LLM provider.

  ## Options
  - `:provider` - The string identifier of the provider configured in `:llm_providers`.
    Defaults to the first provider found or "mock".
  - `:model` - The model identifier to use. Defaults to the provider's default model.
  - `:tools` - A list of function tools for the model to call.
  """
  @spec chat_completion([message()], keyword()) :: chat_result()
  def chat_completion(messages, opts \\ []) do
    registry = Application.get_env(:pincer, :llm_providers, %{})

    # Setup default provider (fallback to first available if none specified)
    default_provider_key =
      Application.get_env(
        :pincer,
        :default_llm_provider,
        case Map.keys(registry) do
          [] -> "mock"
          [first | _] -> first
        end
      )

    requested_provider_id = Keyword.get(opts, :provider, default_provider_key)

    provider_id =
      maybe_route_around_cooldown(
        requested_provider_id,
        registry,
        Keyword.has_key?(opts, :provider)
      )

    if provider_id == "mock" or not is_map_key(registry, provider_id) do
      Logger.warning("Provider '#{provider_id}' not found. Using MOCK mode.")
      simulate_response(messages)
    else
      config = registry[provider_id]
      requested_profile = Keyword.get(opts, :auth_profile)

      case AuthProfiles.resolve(provider_id, config, requested_profile: requested_profile) do
        {:ok, auth_selection} ->
          model = Keyword.get(opts, :model, config[:default_model])
          tools = Keyword.get(opts, :tools, [])
          adapter = config[:adapter]
          config_with_auth = auth_selection.config

          auth_context = %{
            provider_id: provider_id,
            profile: auth_selection.profile
          }

          retry_policy = retry_policy()

          failover_state =
            Keyword.get_lazy(opts, :failover_state, fn ->
              FailoverPolicy.initial_state(
                provider: provider_id,
                model: model,
                registry: registry
              )
            end)

          do_request_with_retry(
            :chat_completion,
            adapter,
            messages,
            model,
            config_with_auth,
            tools,
            retry_policy.max_retries,
            retry_policy.initial_backoff,
            retry_policy,
            System.monotonic_time(:millisecond),
            failover_state,
            auth_context
          )

        {:error, :missing_credentials} ->
          {:error, :missing_credentials}

        {:error, :all_profiles_cooling_down} ->
          {:error, :all_profiles_cooling_down}
      end
    end
  end

  @doc """
  Returns a list of all configured LLM providers dynamically from the registry.

  Each provider entry contains:
  - `:id` - The string identifier used in `chat_completion/2` options
  - `:name` - A capitalized human-readable description of the provider
  """
  @spec list_providers() :: [%{id: String.t(), name: String.t()}]
  def list_providers do
    ModelRegistry.list_providers(Application.get_env(:pincer, :llm_providers, %{}))
  end

  @doc """
  Returns a list containing the default model for a specific provider.
  Unlike the hardcoded version, this pulls from the dynamic config.
  """
  @spec list_models(String.t()) :: [String.t()]
  def list_models(provider_id) do
    ModelRegistry.list_models(provider_id, Application.get_env(:pincer, :llm_providers, %{}))
  end

  @doc """
  Sends a streaming chat completion request to the configured LLM provider.
  Returns an Enumerable of message chunks.
  """
  @spec stream_completion([message()], keyword()) :: {:ok, Enumerable.t()} | {:error, any()}
  def stream_completion(messages, opts \\ []) do
    registry = Application.get_env(:pincer, :llm_providers, %{})

    default_provider_key =
      Application.get_env(
        :pincer,
        :default_llm_provider,
        case Map.keys(registry) do
          [] -> "mock"
          [first | _] -> first
        end
      )

    requested_provider_id = Keyword.get(opts, :provider, default_provider_key)

    provider_id =
      maybe_route_around_cooldown(
        requested_provider_id,
        registry,
        Keyword.has_key?(opts, :provider)
      )

    if provider_id == "mock" or not is_map_key(registry, provider_id) do
      Logger.warning("Streaming provider '#{provider_id}' not found. Using MOCK mode.")
      {:ok, [%{"choices" => [%{"delta" => %{"content" => "[MOCK STREAM] Hello!"}}]}]}
    else
      config = registry[provider_id]
      requested_profile = Keyword.get(opts, :auth_profile)

      case AuthProfiles.resolve(provider_id, config, requested_profile: requested_profile) do
        {:ok, auth_selection} ->
          model = Keyword.get(opts, :model, config[:default_model])
          tools = Keyword.get(opts, :tools, [])
          adapter = config[:adapter]
          config_with_auth = auth_selection.config

          auth_context = %{
            provider_id: provider_id,
            profile: auth_selection.profile
          }

          retry_policy = retry_policy()

          failover_state =
            Keyword.get_lazy(opts, :failover_state, fn ->
              FailoverPolicy.initial_state(
                provider: provider_id,
                model: model,
                registry: registry
              )
            end)

          do_request_with_retry(
            :stream_completion,
            adapter,
            messages,
            model,
            config_with_auth,
            tools,
            retry_policy.max_retries,
            retry_policy.initial_backoff,
            retry_policy,
            System.monotonic_time(:millisecond),
            failover_state,
            auth_context
          )

        {:error, :missing_credentials} ->
          {:error, :missing_credentials}

        {:error, :all_profiles_cooling_down} ->
          {:error, :all_profiles_cooling_down}
      end
    end
  end

  defp do_request_with_retry(
         action,
         adapter,
         messages,
         model,
         config,
         tools,
         retries,
         delay,
         retry_policy,
         started_at_ms,
         failover_state,
         auth_context
       ) do
    # Dynamically call the adapter function based on action (:chat_completion or :stream_completion)
    result = apply(adapter, action, [messages, model, config, tools])

    case result do
      {:ok, result} ->
        maybe_clear_provider_cooldown(failover_state)
        maybe_clear_auth_profile_cooldown(auth_context)

        case normalize_success(action, result) do
          {:ok, normalized} ->
            {:ok, normalized}

          {:error, stream_reason} ->
            maybe_fallback_stream_to_chat(
              action,
              adapter,
              messages,
              model,
              config,
              tools,
              retries,
              delay,
              retry_policy,
              started_at_ms,
              stream_reason,
              failover_state,
              auth_context
            )
        end

      {:error, raw_reason} ->
        reason = normalize_reason(raw_reason)

        cond do
          quota_exhausted?(reason) ->
            Logger.error("Out of credits/quota detected. Failing fast without retry.")
            CoreTelemetry.emit_error(reason, %{action: action, reason: :quota_exhausted})
            {:error, reason}

          retries > 0 and RetryPolicy.retryable?(reason) ->
            elapsed_ms = elapsed_since(started_at_ms)

            if elapsed_ms >= retry_policy.max_elapsed_ms do
              Logger.warning(
                "Retry deadline reached (#{elapsed_ms}ms >= #{retry_policy.max_elapsed_ms}ms). Stopping retries."
              )

              CoreTelemetry.emit_error({:retry_timeout, reason}, %{
                action: action,
                reason: :deadline_reached
              })

              {:error, {:retry_timeout, reason}}
            else
              base_wait =
                case RetryPolicy.retry_after_ms(reason, elapsed_ms, retry_policy.max_elapsed_ms) do
                  ms when is_integer(ms) and ms > 0 -> ms
                  _ -> delay
                end

              wait_ms = with_jitter(base_wait, retry_policy.jitter_ratio)

              if elapsed_ms + wait_ms > retry_policy.max_elapsed_ms do
                Logger.warning(
                  "Retry deadline would be exceeded by next wait (elapsed=#{elapsed_ms}ms, wait=#{wait_ms}ms, max=#{retry_policy.max_elapsed_ms}ms)."
                )

                CoreTelemetry.emit_error({:retry_timeout, reason}, %{
                  action: action,
                  reason: :deadline_exceeded_by_wait
                })

                {:error, {:retry_timeout, reason}}
              else
                CoreTelemetry.emit_retry(reason, %{
                  action: action,
                  wait_ms: wait_ms,
                  retries_left: retries
                })

                Logger.warning(
                  "Transient LLM failure (#{reason_label(reason)}). Waiting #{wait_ms}ms... (Retries left: #{retries})"
                )

                receive do
                  {:model_changed, new_provider, new_model} ->
                    {latest_provider, latest_model} = drain_model_changed(new_provider, new_model)

                    Logger.info(
                      "[CLIENT] Model changed mid-backoff to #{latest_provider}. SWAPPING NOW."
                    )

                    if action == :chat_completion do
                      chat_completion(messages,
                        provider: latest_provider,
                        model: latest_model,
                        tools: tools
                      )
                    else
                      stream_completion(messages,
                        provider: latest_provider,
                        model: latest_model,
                        tools: tools
                      )
                    end
                after
                  wait_ms ->
                    next_delay =
                      delay
                      |> Kernel.*(2)
                      |> max(base_wait)
                      |> min(retry_policy.max_backoff)

                    do_request_with_retry(
                      action,
                      adapter,
                      messages,
                      model,
                      config,
                      tools,
                      retries - 1,
                      next_delay,
                      retry_policy,
                      started_at_ms,
                      failover_state,
                      auth_context
                    )
                end
              end
            end

          true ->
            maybe_handle_terminal_failure(
              action,
              adapter,
              messages,
              model,
              config,
              tools,
              retries,
              delay,
              retry_policy,
              started_at_ms,
              reason,
              failover_state,
              auth_context
            )
        end
    end
  end

  defp normalize_success(:stream_completion, stream) do
    if valid_stream?(stream) do
      {:ok, stream}
    else
      {:error, {:invalid_stream_response, stream}}
    end
  end

  defp normalize_success(_action, result), do: {:ok, result}

  defp valid_stream?(stream) do
    cond do
      is_nil(Enumerable.impl_for(stream)) ->
        false

      true ->
        try do
          _ = Enum.take(stream, 0)
          true
        rescue
          _ -> false
        catch
          _, _ -> false
        end
    end
  end

  defp maybe_handle_terminal_failure(
         :stream_completion,
         _adapter,
         messages,
         _model,
         _config,
         tools,
         _retries,
         _delay,
         _retry_policy,
         _started_at_ms,
         reason,
         failover_state,
         auth_context
       ) do
    state = failover_state || FailoverPolicy.initial_state()
    maybe_cooldown_auth_profile(auth_context, reason)
    CooldownStore.cooldown_provider(state.current_provider, reason)
    {action, next_state} = FailoverPolicy.next_action(reason, state)

    case action do
      :retry_same ->
        CoreTelemetry.emit_error(reason, %{
          action: :stream_completion,
          failover_action: :retry_same
        })

        stream_completion(messages,
          provider: next_state.current_provider,
          model: next_state.current_model,
          tools: tools,
          failover_state: next_state
        )

      {:fallback_model, provider, model} ->
        CoreTelemetry.emit_error(reason, %{
          action: :stream_completion,
          failover_action: :fallback_model,
          provider: provider,
          model: model
        })

        stream_completion(messages,
          provider: provider,
          model: model,
          tools: tools,
          failover_state: next_state
        )

      {:fallback_provider, provider, model} ->
        CoreTelemetry.emit_error(reason, %{
          action: :stream_completion,
          failover_action: :fallback_provider,
          provider: provider,
          model: model
        })

        stream_completion(messages,
          provider: provider,
          model: model,
          tools: tools,
          failover_state: next_state
        )

      :stop ->
        attempts = next_state |> FailoverPolicy.summarize_attempts() |> Map.get(:attempts, [])

        CoreTelemetry.emit_error(reason, %{
          action: :stream_completion,
          failover_action: :stop,
          failover_attempts: length(attempts)
        })

        {:error, reason}
    end
  end

  defp maybe_handle_terminal_failure(
         :chat_completion,
         _adapter,
         messages,
         _model,
         _config,
         tools,
         _retries,
         _delay,
         _retry_policy,
         _started_at_ms,
         reason,
         failover_state,
         auth_context
       ) do
    state = failover_state || FailoverPolicy.initial_state()
    maybe_cooldown_auth_profile(auth_context, reason)
    CooldownStore.cooldown_provider(state.current_provider, reason)
    {action, next_state} = FailoverPolicy.next_action(reason, state)

    case action do
      :retry_same ->
        CoreTelemetry.emit_error(reason, %{
          action: :chat_completion,
          failover_action: :retry_same
        })

        chat_completion(messages,
          provider: next_state.current_provider,
          model: next_state.current_model,
          tools: tools,
          failover_state: next_state
        )

      {:fallback_model, provider, model} ->
        CoreTelemetry.emit_error(reason, %{
          action: :chat_completion,
          failover_action: :fallback_model,
          provider: provider,
          model: model
        })

        chat_completion(messages,
          provider: provider,
          model: model,
          tools: tools,
          failover_state: next_state
        )

      {:fallback_provider, provider, model} ->
        CoreTelemetry.emit_error(reason, %{
          action: :chat_completion,
          failover_action: :fallback_provider,
          provider: provider,
          model: model
        })

        chat_completion(messages,
          provider: provider,
          model: model,
          tools: tools,
          failover_state: next_state
        )

      :stop ->
        attempts = next_state |> FailoverPolicy.summarize_attempts() |> Map.get(:attempts, [])

        CoreTelemetry.emit_error(reason, %{
          action: :chat_completion,
          failover_action: :stop,
          failover_attempts: length(attempts)
        })

        {:error, reason}
    end
  end

  defp maybe_handle_terminal_failure(
         action,
         adapter,
         messages,
         model,
         config,
         tools,
         retries,
         delay,
         retry_policy,
         started_at_ms,
         reason,
         failover_state,
         auth_context
       ) do
    maybe_fallback_stream_to_chat(
      action,
      adapter,
      messages,
      model,
      config,
      tools,
      retries,
      delay,
      retry_policy,
      started_at_ms,
      reason,
      failover_state,
      auth_context
    )
  end

  defp maybe_fallback_stream_to_chat(
         :stream_completion,
         adapter,
         messages,
         model,
         config,
         tools,
         retries,
         delay,
         retry_policy,
         started_at_ms,
         reason,
         failover_state,
         auth_context
       ) do
    Logger.warning(
      "[CLIENT] Streaming unavailable (#{reason_label(reason)}). Falling back to single-shot completion."
    )

    case do_request_with_retry(
           :chat_completion,
           adapter,
           messages,
           model,
           config,
           tools,
           retries,
           delay,
           retry_policy,
           started_at_ms,
           failover_state,
           auth_context
         ) do
      {:ok, message} ->
        {:ok, chat_message_to_stream_chunks(message)}

      {:error, fallback_reason} ->
        CoreTelemetry.emit_error(fallback_reason, %{
          action: :stream_completion,
          reason: :fallback_chat_failed
        })

        {:error, fallback_reason}
    end
  end

  defp maybe_fallback_stream_to_chat(
         _action,
         _adapter,
         _messages,
         _model,
         _config,
         _tools,
         _retries,
         _delay,
         _retry_policy,
         _started_at_ms,
         reason,
         _failover_state,
         _auth_context
       ) do
    CoreTelemetry.emit_error(reason, %{action: :chat_completion})
    {:error, reason}
  end

  defp chat_message_to_stream_chunks(message) when is_map(message) do
    content =
      case message["content"] do
        text when is_binary(text) -> text
        _ -> ""
      end

    tool_calls = message["tool_calls"] || []

    delta = %{}
    delta = if content == "", do: delta, else: Map.put(delta, "content", content)

    delta =
      if is_list(tool_calls) and tool_calls != [] do
        Map.put(
          delta,
          "tool_calls",
          Enum.with_index(tool_calls)
          |> Enum.map(fn {tool_call, index} ->
            %{
              "index" => index,
              "id" => tool_call["id"],
              "function" => %{
                "name" => get_in(tool_call, ["function", "name"]) || "",
                "arguments" => get_in(tool_call, ["function", "arguments"]) || ""
              }
            }
          end)
        )
      else
        delta
      end

    [%{"choices" => [%{"delta" => delta}]}]
  end

  defp chat_message_to_stream_chunks(_), do: [%{"choices" => [%{"delta" => %{"content" => ""}}]}]

  defp simulate_response(_messages) do
    {:ok, %{"role" => "assistant", "content" => "[MOCK] Hello! Configure your LLM providers."}}
  end

  defp drain_model_changed(provider, model) do
    receive do
      {:model_changed, newer_provider, newer_model} ->
        drain_model_changed(newer_provider, newer_model)
    after
      0 ->
        {provider, model}
    end
  end

  defp retry_policy do
    config = Application.get_env(:pincer, :llm_retry, [])

    fetch = fn key, default ->
      case config do
        map when is_map(map) -> Map.get(map, key, default)
        list when is_list(list) -> Keyword.get(list, key, default)
        _ -> default
      end
    end

    %{
      max_retries:
        positive_integer(fetch.(:max_retries, @default_max_retries), @default_max_retries),
      initial_backoff:
        positive_integer(
          fetch.(:initial_backoff, @default_initial_backoff),
          @default_initial_backoff
        ),
      max_backoff:
        positive_integer(fetch.(:max_backoff, @default_max_backoff), @default_max_backoff),
      max_elapsed_ms:
        positive_integer(
          fetch.(:max_elapsed_ms, @default_max_elapsed_ms),
          @default_max_elapsed_ms
        ),
      jitter_ratio:
        float_in_range(
          fetch.(:jitter_ratio, @default_jitter_ratio),
          0.0,
          1.0,
          @default_jitter_ratio
        )
    }
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp float_in_range(value, min_value, max_value, _default)
       when is_float(value) and value >= min_value and value <= max_value,
       do: value

  defp float_in_range(value, min_value, max_value, _default)
       when is_integer(value) and value >= min_value and value <= max_value,
       do: value / 1

  defp float_in_range(_value, _min, _max, default), do: default

  defp normalize_reason({:error, reason}), do: normalize_reason(reason)
  defp normalize_reason({:EXIT, reason}), do: normalize_reason(reason)
  defp normalize_reason(reason), do: reason

  defp quota_exhausted?({:http_error, 429, body}) when is_binary(body) do
    String.contains?(body, "余额不足") or String.contains?(body, "insufficient_quota")
  end

  defp quota_exhausted?({:http_error, 429, body, _meta}) when is_binary(body) do
    String.contains?(body, "余额不足") or String.contains?(body, "insufficient_quota")
  end

  defp quota_exhausted?(_), do: false

  @doc false
  def parse_retry_after(value, now_ms \\ System.system_time(:millisecond))
  def parse_retry_after(value, now_ms), do: RetryPolicy.parse_retry_after(value, now_ms)

  defp maybe_route_around_cooldown(provider_id, _registry, true), do: provider_id

  defp maybe_route_around_cooldown(provider_id, _registry, _) when provider_id in [nil, ""],
    do: provider_id

  defp maybe_route_around_cooldown("mock", _registry, _), do: "mock"

  defp maybe_route_around_cooldown(provider_id, registry, _explicit?) when is_map(registry) do
    if CooldownStore.cooling_down?(provider_id) do
      candidates =
        registry
        |> ModelRegistry.list_providers()
        |> Enum.map(& &1.id)
        |> CooldownStore.available_providers()

      case candidates do
        [candidate | _] when is_binary(candidate) and candidate != "" ->
          if candidate != provider_id do
            Logger.warning(
              "[CLIENT] Default provider #{provider_id} is cooling down. Routing request to #{candidate}."
            )
          end

          candidate

        _ ->
          provider_id
      end
    else
      provider_id
    end
  end

  defp maybe_route_around_cooldown(provider_id, _registry, _), do: provider_id

  defp maybe_clear_provider_cooldown(failover_state) when is_map(failover_state) do
    case Map.get(failover_state, :current_provider) do
      provider when is_binary(provider) and provider != "" ->
        CooldownStore.clear_provider(provider)

      _ ->
        :ok
    end
  end

  defp maybe_clear_provider_cooldown(_), do: :ok

  defp maybe_cooldown_auth_profile(%{provider_id: provider, profile: profile}, reason)
       when is_binary(provider) and provider != "" and is_binary(profile) and profile != "" do
    AuthProfiles.cooldown_profile(provider, profile, reason)
  end

  defp maybe_cooldown_auth_profile(_context, _reason), do: :ok

  defp maybe_clear_auth_profile_cooldown(%{provider_id: provider, profile: profile})
       when is_binary(provider) and provider != "" and is_binary(profile) and profile != "" do
    AuthProfiles.clear_profile(provider, profile)
  end

  defp maybe_clear_auth_profile_cooldown(_context), do: :ok

  defp elapsed_since(started_at_ms), do: System.monotonic_time(:millisecond) - started_at_ms

  defp with_jitter(base_ms, jitter_ratio) when is_integer(base_ms) and base_ms >= 0 do
    jitter = trunc(base_ms * jitter_ratio)

    if jitter <= 0 do
      base_ms
    else
      random_delta = :rand.uniform(jitter * 2 + 1) - jitter - 1
      max(0, base_ms + random_delta)
    end
  end

  defp reason_label({:http_error, status, _}), do: "HTTP #{status}"
  defp reason_label({:http_error, status, _, _}), do: "HTTP #{status}"
  defp reason_label(%Req.TransportError{reason: reason}), do: "transport #{inspect(reason)}"
  defp reason_label({:timeout, _}), do: "internal timeout"
  defp reason_label(other), do: inspect(other)
end
