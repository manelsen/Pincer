defmodule Pincer.Core.LLM.CooldownStore do
  @moduledoc """
  Cross-request cooldown memory for LLM providers.

  Stores temporary provider unavailability windows keyed by provider id.
  """

  alias Pincer.Core.ErrorClass

  @table :pincer_llm_cooldown_store

  @default_durations %{
    http_429: 20_000,
    http_5xx: 10_000,
    transport_timeout: 8_000,
    transport_connect: 8_000,
    transport_dns: 8_000,
    process_timeout: 8_000
  }

  @spec cooldown_provider(String.t(), term(), keyword()) :: :ok
  def cooldown_provider(provider, reason_or_class, opts \\ [])

  def cooldown_provider(provider, reason_or_class, opts)
      when is_binary(provider) and provider != "" do
    class = classify(reason_or_class)
    duration_ms = duration_ms(class, opts)

    if duration_ms > 0 do
      now_ms = now_ms()
      expires_at = now_ms + duration_ms

      ensure_table()

      case :ets.lookup(@table, provider) do
        [{^provider, existing_expires_at, _existing_class}]
        when existing_expires_at >= expires_at ->
          :ok

        _ ->
          :ets.insert(@table, {provider, expires_at, class})
          :ok
      end
    else
      :ok
    end
  end

  def cooldown_provider(_provider, _reason_or_class, _opts), do: :ok

  @spec cooling_down?(String.t()) :: boolean()
  def cooling_down?(provider) when is_binary(provider) and provider != "" do
    ensure_table()

    case :ets.lookup(@table, provider) do
      [{^provider, expires_at, _class}] ->
        if expires_at > now_ms() do
          true
        else
          :ets.delete(@table, provider)
          false
        end

      _ ->
        false
    end
  end

  def cooling_down?(_provider), do: false

  @spec available_providers([String.t()]) :: [String.t()]
  def available_providers(providers) when is_list(providers) do
    Enum.filter(providers, fn provider -> not cooling_down?(provider) end)
  end

  @spec clear_provider(String.t()) :: :ok
  def clear_provider(provider) when is_binary(provider) and provider != "" do
    ensure_table()
    :ets.delete(@table, provider)
    :ok
  end

  def clear_provider(_provider), do: :ok

  @doc false
  @spec reset() :: :ok
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp duration_ms(class, opts) when is_list(opts) do
    case Keyword.get(opts, :duration_ms) do
      value when is_integer(value) and value > 0 ->
        value

      _ ->
        class_durations = configured_durations()

        case Map.get(class_durations, class, Map.get(class_durations, :unknown, 0)) do
          value when is_integer(value) and value > 0 -> value
          _ -> 0
        end
    end
  end

  defp configured_durations do
    config = Application.get_env(:pincer, :llm_cooldown, [])
    durations = fetch_key(config, :durations_ms, %{})

    map =
      cond do
        is_map(durations) -> durations
        is_list(durations) -> Map.new(durations)
        true -> %{}
      end

    Map.merge(@default_durations, map)
  end

  defp classify(reason_or_class) when is_atom(reason_or_class), do: reason_or_class
  defp classify(reason_or_class), do: ErrorClass.classify(reason_or_class)

  defp fetch_key(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp fetch_key(list, key, default) when is_list(list) do
    string_key = to_string(key)

    cond do
      Keyword.keyword?(list) ->
        Keyword.get(list, key, default)

      true ->
        Enum.find_value(list, default, fn
          {^key, value} ->
            value

          {list_key, value} when is_binary(list_key) and list_key == string_key ->
            value

          {list_key, value} when is_atom(list_key) ->
            if Atom.to_string(list_key) == string_key, do: value, else: nil

          %{} = map ->
            Map.get(map, key) || Map.get(map, string_key)

          _ ->
            nil
        end)
    end
  end

  defp fetch_key(_other, _key, default), do: default

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end
end
