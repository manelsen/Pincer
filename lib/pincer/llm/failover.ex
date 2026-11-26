defmodule Pincer.LLM.Failover do
  @moduledoc """
  Provider routing, auth profile resolution, failover state initialization, and
  retry-engine handoff for chat and streaming completions.
  """

  alias Pincer.Core.AuthProfiles
  alias Pincer.Core.LLM.FailoverPolicy
  alias Pincer.LLM.{CooldownRouting, FailoverDispatch, RetryEngine}

  @doc """
  Dispatches a chat or streaming completion through cooldown routing, auth
  profile resolution, and `Pincer.LLM.RetryEngine`.
  """
  @spec dispatch(FailoverDispatch.action(), [map()], keyword()) :: term()
  def dispatch(action, messages, opts \\ [])
      when action in [:chat_completion, :stream_completion] do
    registry = CooldownRouting.provider_registry()
    provider = resolve_provider(registry, opts)

    cond do
      provider == "mock" ->
        simulate_response(action)

      not is_map_key(registry, provider) ->
        {:error, {:provider_not_found, provider}}

      true ->
        dispatch_to_provider(action, messages, opts, provider, registry)
    end
  end

  @doc """
  Resolves the effective provider for `opts`, routing around a cooling-down
  default provider when `:provider` was not explicitly specified.
  """
  @spec resolve_provider(map(), keyword()) :: String.t() | nil
  def resolve_provider(registry, opts) when is_map(registry) do
    default_provider =
      Application.get_env(:pincer, :default_llm_provider, Enum.at(Map.keys(registry), 0, "mock"))

    requested_provider = Keyword.get(opts, :provider, default_provider)

    CooldownRouting.route_around_cooldown(
      requested_provider,
      registry,
      Keyword.has_key?(opts, :provider)
    )
  end

  @doc """
  Resolves credentials for `provider` using `Pincer.Core.AuthProfiles`,
  normalizing `:missing_credentials` with the configured env key name.
  """
  @spec resolve_auth(String.t(), map(), keyword()) ::
          {:ok, AuthProfiles.selection()}
          | {:error, {:missing_credentials, String.t()} | :all_profiles_cooling_down}
  def resolve_auth(provider, config, opts \\ []) when is_binary(provider) and is_map(config) do
    requested_profile = Keyword.get(opts, :auth_profile)

    case AuthProfiles.resolve(provider, config, requested_profile: requested_profile) do
      {:ok, auth} ->
        {:ok, auth}

      {:error, :missing_credentials} ->
        {:error, {:missing_credentials, config[:env_key] || "API_KEY"}}

      {:error, :all_profiles_cooling_down} ->
        {:error, :all_profiles_cooling_down}
    end
  end

  @doc """
  Returns the failover state from `opts[:failover_state]` if present, or initializes
  a new deterministic state via `Pincer.Core.LLM.FailoverPolicy.initial_state/1`.
  """
  @spec initial_state(keyword()) :: FailoverPolicy.state()
  def initial_state(opts) do
    case Keyword.get(opts, :failover_state) do
      %{} = state ->
        state

      _ ->
        FailoverPolicy.initial_state(
          provider: Keyword.get(opts, :provider),
          model: Keyword.get(opts, :model),
          registry: Keyword.get(opts, :registry, %{})
        )
    end
  end

  defp dispatch_to_provider(action, messages, opts, provider, registry) do
    config = Map.fetch!(registry, provider)

    with {:ok, auth} <- resolve_auth(provider, config, opts) do
      model = Keyword.get(opts, :model, config[:default_model])

      failover_state =
        initial_state(
          failover_state: Keyword.get(opts, :failover_state),
          provider: provider,
          model: model,
          registry: registry
        )

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
    end
  end

  defp simulate_response(:chat_completion) do
    {:ok, %{"role" => "assistant", "content" => "[MOCK] Hello! Configure your LLM providers."},
     nil}
  end

  defp simulate_response(:stream_completion) do
    {:ok, [%{"choices" => [%{"delta" => %{"content" => "[MOCK STREAM] Hello!"}}]}]}
  end
end
