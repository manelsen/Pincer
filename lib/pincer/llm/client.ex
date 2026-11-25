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
  alias Pincer.Core.LLM.FailoverPolicy
  alias Pincer.Core.Models.Registry, as: ModelRegistry
  alias Pincer.Core.RetryPolicy
  alias Pincer.LLM.{CooldownRouting, RetryEngine}
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
    dispatch(:chat_completion, messages, opts)
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
    dispatch(:stream_completion, messages, opts)
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

  defp dispatch(action, messages, opts) do
    registry = CooldownRouting.provider_registry()

    default_provider =
      Application.get_env(:pincer, :default_llm_provider, Enum.at(Map.keys(registry), 0, "mock"))

    requested_provider = Keyword.get(opts, :provider, default_provider)

    provider =
      CooldownRouting.route_around_cooldown(
        requested_provider,
        registry,
        Keyword.has_key?(opts, :provider)
      )

    cond do
      provider == "mock" ->
        simulate_response(action)

      not is_map_key(registry, provider) ->
        {:error, {:provider_not_found, provider}}

      true ->
        dispatch_to_provider(action, messages, opts, provider, registry)
    end
  end

  defp dispatch_to_provider(action, messages, opts, provider, registry) do
    config = Map.fetch!(registry, provider)
    requested_profile = Keyword.get(opts, :auth_profile)

    case AuthProfiles.resolve(provider, config, requested_profile: requested_profile) do
      {:ok, auth} ->
        model = Keyword.get(opts, :model, config[:default_model])

        failover_state =
          Keyword.get_lazy(opts, :failover_state, fn ->
            FailoverPolicy.initial_state(provider: provider, model: model, registry: registry)
          end)

        request = %{
          adapter: config[:adapter],
          messages: messages,
          model: model,
          config: auth.config,
          tools: Keyword.get(opts, :tools, []),
          failover_state: failover_state,
          auth_context: %{provider_id: provider, profile: auth.profile}
        }

        RetryEngine.run(action, request, &dispatch/3)

      {:error, :missing_credentials} ->
        {:error, {:missing_credentials, config[:env_key] || "API_KEY"}}

      {:error, :all_profiles_cooling_down} ->
        {:error, :all_profiles_cooling_down}
    end
  end

  defp simulate_response(:chat_completion) do
    {:ok, %{"role" => "assistant", "content" => "[MOCK] Hello! Configure your LLM providers."},
     nil}
  end

  defp simulate_response(:stream_completion) do
    {:ok, [%{"choices" => [%{"delta" => %{"content" => "[MOCK STREAM] Hello!"}}]}]}
  end

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

  defp normalize_error_result({:error, reason}),
    do: {:error, RetryEngine.normalize_reason(reason)}

  defp normalize_error_result(other), do: other

  @doc false
  def parse_retry_after(value, now_ms \\ System.system_time(:millisecond))
  def parse_retry_after(value, now_ms), do: RetryPolicy.parse_retry_after(value, now_ms)
end
