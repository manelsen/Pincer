defmodule Pincer.Test.Support.LLMHelpers do
  @moduledoc """
  Shared helpers for overriding `:pincer` LLM provider and application env
  configuration in tests with automatic `ExUnit.Callbacks.on_exit/1` cleanup.
  """

  @app :pincer

  @doc """
  Temporarily sets `key` under `:pincer` to `value` and restores the previous
  state (or deletes the key if it was unset) when the test exits.
  """
  @spec put_app_env!(atom(), term()) :: term()
  def put_app_env!(key, value) when is_atom(key) do
    previous = Application.fetch_env(@app, key)
    Application.put_env(@app, key, value)
    ExUnit.Callbacks.on_exit(fn -> restore_app_env(key, previous) end)
    value
  end

  @doc """
  Temporarily replaces `:pincer, :llm_providers` with `providers` and restores
  the previous value on test exit.

  ## Options

    * `:default` - Also sets `:default_llm_provider` (restored on exit).
  """
  @spec put_providers!(term(), keyword()) :: term()
  def put_providers!(providers, opts \\ []) when is_list(opts) do
    put_app_env!(:llm_providers, providers)

    case Keyword.fetch(opts, :default) do
      {:ok, default_provider} -> put_default_provider!(default_provider)
      :error -> :ok
    end

    providers
  end

  @doc """
  Merges a single `provider_id => config` entry into `:pincer, :llm_providers`,
  restoring the previous map on test exit.

  ## Options

    * `:default` - When `true`, also sets `:default_llm_provider` to `provider_id`.
  """
  @spec put_provider!(String.t(), map(), keyword()) :: map()
  def put_provider!(provider_id, config, opts \\ [])
      when is_binary(provider_id) and is_map(config) and is_list(opts) do
    current =
      case Application.get_env(@app, :llm_providers) do
        map when is_map(map) -> map
        _ -> %{}
      end

    updated = Map.put(current, provider_id, config)
    put_app_env!(:llm_providers, updated)

    if Keyword.get(opts, :default, false) do
      put_default_provider!(provider_id)
    end

    updated
  end

  @doc """
  Temporarily sets `:pincer, :default_llm_provider` and restores it on exit.
  """
  @spec put_default_provider!(String.t()) :: String.t()
  def put_default_provider!(provider_id) when is_binary(provider_id) do
    put_app_env!(:default_llm_provider, provider_id)
  end

  @doc """
  Temporarily sets an OS environment variable and restores or deletes it on exit.
  """
  @spec put_system_env!(String.t(), String.t()) :: String.t()
  def put_system_env!(key, value) when is_binary(key) and is_binary(value) do
    previous = System.get_env(key)
    System.put_env(key, value)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        nil -> System.delete_env(key)
        prev -> System.put_env(key, prev)
      end
    end)

    value
  end

  @doc """
  Builds a standard mock provider configuration map using `Pincer.LLM.ClientMock`.
  """
  @spec mock_provider_config(map()) :: map()
  def mock_provider_config(overrides \\ %{}) when is_map(overrides) do
    Map.merge(
      %{
        adapter: Pincer.LLM.ClientMock,
        base_url: "http://mock",
        default_model: "test-model",
        env_key: "MOCK_KEY"
      },
      overrides
    )
  end

  defp restore_app_env(key, :error), do: Application.delete_env(@app, key)
  defp restore_app_env(key, {:ok, value}), do: Application.put_env(@app, key, value)
end
