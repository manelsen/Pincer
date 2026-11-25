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

      iex> PincerPorts.LLM.chat_completion([
      ...>   %{"role" => "user", "content" => "Hello!"}
      ...> ], provider: "openrouter")
      {:ok, %{"role" => "assistant", "content" => "Hello! How can I help you?"}}
  """

  @behaviour PincerPorts.LLM
  require Logger
  alias Pincer.Core.AuthProfiles
  alias Pincer.Core.LLM.CooldownStore
  alias Pincer.Core.LLM.FailoverPolicy
  alias Pincer.Core.Models.Registry, as: ModelRegistry
  alias Pincer.Core.Policy
  alias Pincer.Core.RetryPolicy
  alias PincerPorts.Structs.Usage
  alias Pincer.Core.Telemetry, as: CoreTelemetry
  alias Pincer.LLM.CooldownRouting
  alias Pincer.LLM.RetrySettings
  alias Pincer.LLM.StreamFallback
  alias Pincer.Utils.ETSHelper

  @type message :: PincerPorts.LLM.Provider.message()
  @type tool :: PincerPorts.LLM.Provider.tool()
  @type chat_result :: PincerPorts.LLM.Provider.chat_result()

  @doc """
  Sends a chat completion request to the configured LLM provider.

  ## Options
  - `:provider` - The string identifier of the provider configured in `:llm_providers`.
    Defaults to the first provider found or "mock".
  - `:model` - The model identifier to use. Defaults to the provider's default model.
  - `:tools` - A list of function tools for the model to call.

  When the retry budget is exhausted, `Pincer.LLM.FailoverDispatch` either
  re-enters here on another route or returns the final error.
  """
  @spec chat_completion([message()], keyword()) :: chat_result()
  def chat_completion(messages, opts \\ []) do
    registry = CooldownRouting.provider_registry()

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
      CooldownRouting.route_around_cooldown(
        requested_provider_id,
        registry,
        Keyword.has_key?(opts, :provider)
      )

    cond do
      provider_id == "mock" ->
        simulate_response(messages)

      not is_map_key(registry, provider_id) ->
        {:error, {:provider_not_found, provider_id}}

      true ->
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
            env_key = config[:env_key] || "API_KEY"
            {:error, {:missing_credentials, env_key}}

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
    ModelRegistry.list_providers(model_selection_registry())
  end

  @doc """
  Returns the raw configuration map for a given provider.
  """
  @spec provider_config(String.t()) :: map() | nil
  def provider_config(provider_id) do
    registry = CooldownRouting.provider_registry()
    registry[provider_id]
  end

  @doc """
  Returns available models for a specific provider from the model-selection

  registry (config.yaml `llm` with fallback to `:llm_providers`).

  Attempts dynamic discovery from provider API with 1-hour cache.
  """
  @spec list_models(String.t()) :: [String.t()]
  def list_models(provider_id) do
    cache_key = {:models, provider_id, models_config_fingerprint(provider_id)}

    case get_cached_models(cache_key) do
      {:ok, models} ->
        models

      :miss ->
        models = fetch_models_from_provider(provider_id)
        put_cached_models(cache_key, models)
        models
    end
  end

  # The cached model list belongs to one provider configuration, not just to a
  # provider id. Without the fingerprint, a config reload (or a test that swaps
  # `:llm_providers`) kept serving the previous list for the whole TTL.
  defp models_config_fingerprint(provider_id) do
    :erlang.phash2({provider_config(provider_id), model_selection_registry()})
  end

  defp fetch_models_from_provider("mock"),
    do: ModelRegistry.list_models("mock", model_selection_registry())

  defp fetch_models_from_provider(provider_id) do
    registry = CooldownRouting.provider_registry()
    config = registry[provider_id]
    do_fetch_models(provider_id, config)
  end

  defp do_fetch_models(provider_id, nil),
    do: ModelRegistry.list_models(provider_id, model_selection_registry())

  defp do_fetch_models(provider_id, config) do
    adapter = config[:adapter]

    case AuthProfiles.resolve(provider_id, config, requested_profile: nil) do
      {:ok, auth_selection} ->
        config_with_auth = auth_selection.config

        case apply(adapter, :list_models, [config_with_auth]) do
          {:ok, models} when is_list(models) and models != [] ->
            models

          _ ->
            ModelRegistry.list_models(provider_id, model_selection_registry())
        end

      _ ->
        ModelRegistry.list_models(provider_id, model_selection_registry())
    end
  end

  # Simple ETS-based cache for 1 hour
  @cache_table :pincer_llm_cache
  @cache_ttl_seconds 3600

  defp get_cached_models(key) do
    ensure_cache_table()

    case :ets.lookup(@cache_table, key) do
      [{^key, models, expiry}] ->
        if System.system_time(:second) < expiry do
          {:ok, models}
        else
          :ets.delete(@cache_table, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp put_cached_models(key, models) do
    ensure_cache_table()
    expiry = System.system_time(:second) + @cache_ttl_seconds
    :ets.insert(@cache_table, {key, models, expiry})
  end

  defp ensure_cache_table do
    _ =
      ETSHelper.ensure_named_table(@cache_table,
        options: [:named_table, :public, :set, read_concurrency: true]
      )
  end

  @doc """
  Sends a streaming chat completion request to the configured LLM provider.
  Returns an Enumerable of message chunks.
  """
  @spec stream_completion([message()], keyword()) :: {:ok, Enumerable.t()} | {:error, any()}
  def stream_completion(messages, opts \\ []) do
    registry = CooldownRouting.provider_registry()

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
      CooldownRouting.route_around_cooldown(
        requested_provider_id,
        registry,
        Keyword.has_key?(opts, :provider)
      )

    cond do
      provider_id == "mock" ->
        {:ok, [%{"choices" => [%{"delta" => %{"content" => "[MOCK STREAM] Hello!"}}]}]}

      not is_map_key(registry, provider_id) ->
        {:error, {:provider_not_found, provider_id}}

      true ->
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
            env_key = config[:env_key] || "API_KEY"
            {:error, {:missing_credentials, env_key}}

          {:error, :all_profiles_cooling_down} ->
            {:error, :all_profiles_cooling_down}
        end
    end
  end

  def transcribe_audio(file_path, opts \\ []) do
    registry = CooldownRouting.provider_registry()
    provider_id = Keyword.get(opts, :provider, "groq_whisper")
    config = registry[provider_id]

    if is_nil(config) do
      {:error, :unknown_provider}
    else
      adapter = config[:adapter]
      requested_profile = Keyword.get(opts, :auth_profile)

      case AuthProfiles.resolve(provider_id, config, requested_profile: requested_profile) do
        {:ok, auth_selection} ->
          model = Keyword.get(opts, :model, config[:default_model])
          config_with_auth = auth_selection.config

          apply(adapter, :transcribe_audio, [file_path, model, config_with_auth])
          |> normalize_error_result()

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def generate_embedding(text, opts \\ []) do
    registry = CooldownRouting.provider_registry()
    provider_id = Keyword.get(opts, :provider, "openrouter")
    config = registry[provider_id]

    if is_nil(config) do
      {:error, :unknown_provider}
    else
      adapter = config[:adapter]
      requested_profile = Keyword.get(opts, :auth_profile)

      case AuthProfiles.resolve(provider_id, config, requested_profile: requested_profile) do
        {:ok, auth_selection} ->
          model =
            Keyword.get(opts, :model) ||
              config[:embedding_model] ||
              if provider_id == "openrouter", do: "baai/bge-m3", else: config[:default_model]

          config_with_auth = auth_selection.config

          generate_embedding_with_fallback(
            adapter,
            text,
            model,
            config_with_auth,
            provider_id,
            opts
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp generate_embedding_with_fallback(adapter, text, model, config, provider_id, opts) do
    case apply(adapter, :generate_embedding, [text, model, config])
         |> normalize_error_result() do
      {:error, reason} = error ->
        maybe_retry_embedding(adapter, text, model, config, provider_id, opts, reason, error)

      other ->
        other
    end
  end

  defp maybe_retry_embedding(adapter, text, model, config, provider_id, opts, reason, error) do
    with true <- provider_id == "openrouter",
         false <- Keyword.has_key?(opts, :model),
         true <- retryable_openrouter_embedding_error?(reason),
         fallback_model when is_binary(fallback_model) <- fallback_embedding_model(model, config) do
      Logger.warning(
        "[LLM] Embedding model #{model} failed via #{provider_id} router. Retrying with #{fallback_model}."
      )

      apply(adapter, :generate_embedding, [text, fallback_model, config])
      |> normalize_error_result()
    else
      _ -> error
    end
  end

  defp retryable_openrouter_embedding_error?(
         {:http_error, status, %{"error" => %{"message" => message}}}
       )
       when status in [200, 404] and is_binary(message) do
    String.contains?(message, "No successful provider responses")
  end

  defp retryable_openrouter_embedding_error?(_), do: false

  defp fallback_embedding_model("baai/bge-m3", config) do
    config[:embedding_fallback_model] || "baai/bge-large-en-v1.5"
  end

  defp fallback_embedding_model(_model, config), do: config[:embedding_fallback_model]

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
      {:ok, message, usage} when action == :chat_completion ->
        CooldownRouting.clear_provider_cooldown(failover_state)
        CooldownRouting.clear_auth_profile_cooldown(auth_context)
        {:ok, Pincer.LLM.ToolParser.parse(message), Usage.normalize_optional(usage)}

      {:ok, stream, usage} when action == :stream_completion ->
        CooldownRouting.clear_provider_cooldown(failover_state)
        CooldownRouting.clear_auth_profile_cooldown(auth_context)

        case normalize_success(action, stream) do
          {:ok, normalized} ->
            {:ok, normalized, Usage.normalize_optional(usage)}

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

      {:ok, stream} ->
        CooldownRouting.clear_provider_cooldown(failover_state)
        CooldownRouting.clear_auth_profile_cooldown(auth_context)

        case normalize_success(action, stream) do
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

          retries > 0 and Policy.classify(:retryable, %{reason: reason}) ->
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
                case Policy.budget(:retry_after_ms, %{
                       reason: reason,
                       elapsed_ms: elapsed_ms,
                       max_elapsed_ms: retry_policy.max_elapsed_ms
                     }) do
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

                notify_runtime_status(%{
                  kind: :retry_wait,
                  action: action,
                  reason: CooldownRouting.reason_label(reason),
                  wait_ms: wait_ms,
                  retries_left: retries
                })

                Logger.warning(
                  "Transient LLM failure (#{CooldownRouting.reason_label(reason)}). Waiting #{wait_ms}ms... (Retries left: #{retries})"
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

  defp model_selection_registry do
    llm_registry = llm_config_registry()
    providers_registry = Application.get_env(:pincer, :llm_providers, %{}) || %{}

    # Merge both, with llm_config_registry (config.yaml) taking precedence
    Map.merge(providers_registry, llm_registry)
  end

  defp llm_config_registry do
    case Application.get_env(:pincer, :llm, %{}) do
      llm when is_map(llm) ->
        Enum.reduce(llm, %{}, fn {provider_id, config}, acc ->
          normalized_provider = normalize_provider_id(provider_id)

          cond do
            normalized_provider == "" ->
              acc

            normalized_provider == "provider" ->
              acc

            not is_map(config) ->
              acc

            true ->
              Map.put(acc, normalized_provider, config)
          end
        end)

      _ ->
        %{}
    end
  end

  defp normalize_provider_id(provider_id) when is_atom(provider_id),
    do: provider_id |> Atom.to_string() |> String.trim()

  defp normalize_provider_id(provider_id) when is_binary(provider_id),
    do: String.trim(provider_id)

  defp normalize_provider_id(provider_id),
    do: provider_id |> to_string() |> String.trim()

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
    if Policy.classify(:fail_fast, %{reason: reason}) do
      CoreTelemetry.emit_error(reason, %{action: :stream_completion, failover_action: :fail_fast})
      {:error, reason}
    else
      state = failover_state || FailoverPolicy.initial_state()
      CooldownRouting.cooldown_auth_profile(auth_context, reason)
      CooldownStore.cooldown_provider(state.current_provider, reason)
      {action, next_state} = FailoverPolicy.next_action(reason, state)

      case action do
        :retry_same ->
          CoreTelemetry.emit_error(reason, %{
            action: :stream_completion,
            failover_action: :retry_same
          })

          notify_runtime_status(%{
            kind: :failover,
            action: :stream_completion,
            failover_action: :retry_same,
            provider: next_state.current_provider,
            model: next_state.current_model,
            reason: CooldownRouting.reason_label(reason)
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

          notify_runtime_status(%{
            kind: :failover,
            action: :stream_completion,
            failover_action: :fallback_model,
            provider: provider,
            model: model,
            reason: CooldownRouting.reason_label(reason)
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

          notify_runtime_status(%{
            kind: :failover,
            action: :stream_completion,
            failover_action: :fallback_provider,
            provider: provider,
            model: model,
            reason: CooldownRouting.reason_label(reason)
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

          notify_runtime_status(%{
            kind: :failover,
            action: :stream_completion,
            failover_action: :stop,
            provider: next_state.current_provider,
            model: next_state.current_model,
            reason: CooldownRouting.reason_label(reason)
          })

          {:error, reason}
      end
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
    if Policy.classify(:fail_fast, %{reason: reason}) do
      CoreTelemetry.emit_error(reason, %{action: :chat_completion, failover_action: :fail_fast})
      {:error, reason}
    else
      state = failover_state || FailoverPolicy.initial_state()
      CooldownRouting.cooldown_auth_profile(auth_context, reason)
      CooldownStore.cooldown_provider(state.current_provider, reason)
      {action, next_state} = FailoverPolicy.next_action(reason, state)

      case action do
        :retry_same ->
          CoreTelemetry.emit_error(reason, %{
            action: :chat_completion,
            failover_action: :retry_same
          })

          notify_runtime_status(%{
            kind: :failover,
            action: :chat_completion,
            failover_action: :retry_same,
            provider: next_state.current_provider,
            model: next_state.current_model,
            reason: CooldownRouting.reason_label(reason)
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

          notify_runtime_status(%{
            kind: :failover,
            action: :chat_completion,
            failover_action: :fallback_model,
            provider: provider,
            model: model,
            reason: CooldownRouting.reason_label(reason)
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

          notify_runtime_status(%{
            kind: :failover,
            action: :chat_completion,
            failover_action: :fallback_provider,
            provider: provider,
            model: model,
            reason: CooldownRouting.reason_label(reason)
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

          notify_runtime_status(%{
            kind: :failover,
            action: :chat_completion,
            failover_action: :stop,
            provider: next_state.current_provider,
            model: next_state.current_model,
            reason: CooldownRouting.reason_label(reason)
          })

          {:error, reason}
      end
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
    StreamFallback.stream_to_chat(
      :stream_completion,
      reason,
      fn ->
        do_request_with_retry(
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
        )
      end,
      fn fallback_reason ->
        CoreTelemetry.emit_error(fallback_reason, %{
          action: :stream_completion,
          reason: :fallback_chat_failed
        })
      end
    )
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
    StreamFallback.stream_to_chat(:chat_completion, reason, fn -> {:error, reason} end, fn r ->
      CoreTelemetry.emit_error(r, %{action: :chat_completion})
    end)
  end

  defp simulate_response(_messages) do
    {:ok, %{"role" => "assistant", "content" => "[MOCK] Hello! Configure your LLM providers."},
     nil}
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

  defp retry_policy, do: RetrySettings.load(Application.get_env(:pincer, :llm_retry, []))

  defp normalize_error_result({:error, reason}), do: {:error, normalize_reason(reason)}
  defp normalize_error_result(other), do: other

  defp normalize_reason({:error, reason}), do: normalize_reason(reason)
  defp normalize_reason({:EXIT, reason}), do: normalize_reason(reason)
  defp normalize_reason(%Req.TransportError{reason: reason}), do: {:transport_error, reason}
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

  defp notify_runtime_status(payload) when is_map(payload) do
    case Process.get(:session_pid) do
      pid when is_pid(pid) ->
        send(pid, {:llm_runtime_status, payload})
        :ok

      _ ->
        :ok
    end
  end
end
