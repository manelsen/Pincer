defmodule Pincer.Core.LLM.FailoverPolicy do
  @moduledoc """
  Deterministic failover policy for LLM provider/model routing.

  The policy converts failure reasons into explicit actions while preserving a
  replayable state transition model.
  """

  alias Pincer.Core.ErrorClass
  alias Pincer.Core.LLM.CooldownStore
  alias Pincer.Core.Models.Registry, as: ModelRegistry
  alias Pincer.Core.RetryPolicy

  @default_retry_same_limit 0

  @type failover_action ::
          :retry_same
          | {:fallback_model, provider :: String.t(), model :: String.t()}
          | {:fallback_provider, provider :: String.t(), model :: String.t()}
          | :stop

  @type state :: map()

  @spec initial_state(keyword()) :: state()
  def initial_state(opts \\ []) do
    registry = Keyword.get(opts, :registry, %{})

    providers =
      registry
      |> ModelRegistry.list_providers()
      |> Enum.map(& &1.id)

    provider =
      case Keyword.get(opts, :provider) do
        value when is_binary(value) and value != "" -> value
        _ -> List.first(providers) || ""
      end

    models_by_provider =
      providers
      |> Enum.map(fn provider_id ->
        {provider_id, ModelRegistry.list_models(provider_id, registry)}
      end)
      |> Map.new()

    model =
      case Keyword.get(opts, :model) do
        value when is_binary(value) and value != "" ->
          value

        _ ->
          models_by_provider
          |> Map.get(provider, [])
          |> List.first() || ""
      end

    retry_same_limit =
      case Keyword.get(opts, :retry_same_limit, @default_retry_same_limit) do
        value when is_integer(value) and value >= 0 -> value
        _ -> @default_retry_same_limit
      end

    %{
      providers: providers,
      models_by_provider: models_by_provider,
      current_provider: provider,
      current_model: model,
      retry_same_limit: retry_same_limit,
      retry_same_count: 0,
      attempted_routes: MapSet.new([{provider, model}]),
      attempts: [],
      terminal_reason: nil
    }
  end

  @spec next_action(reason :: term(), state()) :: {failover_action(), state()}
  def next_action(reason, state) when is_map(state) do
    class = ErrorClass.classify(reason)

    cond do
      not RetryPolicy.retryable?(reason) ->
        {:stop, stop(state, reason, class)}

      state.retry_same_count < state.retry_same_limit ->
        action = :retry_same
        {action, record_retry_same(state, reason, class, action)}

      true ->
        route_after_retry_budget(reason, class, state)
    end
  end

  @spec summarize_attempts(state()) :: %{attempts: [map()], terminal_reason: term() | nil}
  def summarize_attempts(state) when is_map(state) do
    %{
      attempts: Map.get(state, :attempts, []),
      terminal_reason: Map.get(state, :terminal_reason)
    }
  end

  defp route_after_retry_budget(reason, class, state) do
    case next_model_candidate(state) do
      {:ok, model} ->
        provider = state.current_provider
        action = {:fallback_model, provider, model}
        {action, transition_route(state, reason, class, action, provider, model)}

      :none ->
        case next_provider_candidate(state) do
          {:ok, {provider, model}} ->
            action = {:fallback_provider, provider, model}
            {action, transition_route(state, reason, class, action, provider, model)}

          :none ->
            {:stop, stop(state, reason, class)}
        end
    end
  end

  defp stop(state, reason, class) do
    state
    |> add_attempt(reason, class, :stop, state.current_provider, state.current_model)
    |> Map.put(:terminal_reason, reason)
  end

  defp record_retry_same(state, reason, class, action) do
    state
    |> Map.update!(:retry_same_count, &(&1 + 1))
    |> add_attempt(reason, class, action, state.current_provider, state.current_model)
  end

  defp transition_route(state, reason, class, action, provider, model) do
    state
    |> Map.put(:current_provider, provider)
    |> Map.put(:current_model, model)
    |> Map.put(:retry_same_count, 0)
    |> Map.update!(:attempted_routes, &MapSet.put(&1, {provider, model}))
    |> add_attempt(reason, class, action, provider, model)
  end

  defp add_attempt(state, reason, class, action, provider, model) do
    attempt = %{
      reason: reason,
      class: class,
      action: action,
      provider: provider,
      model: model
    }

    Map.update(state, :attempts, [attempt], &(&1 ++ [attempt]))
  end

  defp next_model_candidate(state) do
    provider = state.current_provider
    current_model = state.current_model
    attempted_routes = state.attempted_routes

    candidate =
      state.models_by_provider
      |> Map.get(provider, [])
      |> Enum.find(fn model ->
        model != current_model and not MapSet.member?(attempted_routes, {provider, model})
      end)

    if candidate, do: {:ok, candidate}, else: :none
  end

  defp next_provider_candidate(state) do
    providers = CooldownStore.available_providers(state.providers)
    current_provider = state.current_provider
    attempted_routes = state.attempted_routes

    Enum.reduce_while(providers, :none, fn provider, _acc ->
      cond do
        provider == current_provider ->
          {:cont, :none}

        true ->
          candidate =
            state.models_by_provider
            |> Map.get(provider, [])
            |> Enum.find(fn model -> not MapSet.member?(attempted_routes, {provider, model}) end)

          if candidate do
            {:halt, {:ok, {provider, candidate}}}
          else
            {:cont, :none}
          end
      end
    end)
  end
end
