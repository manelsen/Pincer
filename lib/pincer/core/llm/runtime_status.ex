defmodule Pincer.Core.LLM.RuntimeStatus do
  @moduledoc """
  Formatting contract for runtime LLM retry/failover status updates.

  Produces concise, user-facing text from structured runtime payloads.
  """

  @spec format(map()) :: String.t()
  def format(status) when is_map(status) do
    case read(status, :kind) do
      :retry_wait ->
        format_retry_wait(status)

      :failover ->
        format_failover(status)

      _ ->
        "LLM runtime update in progress."
    end
  end

  def format(_), do: "LLM runtime update in progress."

  defp format_retry_wait(status) do
    wait_ms = read(status, :wait_ms)
    retries_left = read(status, :retries_left)
    reason = read(status, :reason) || "transient failure"

    wait_label =
      case wait_ms do
        value when is_integer(value) and value >= 0 ->
          seconds = value / 1000
          "#{Float.round(seconds, 1)}s"

        _ ->
          "n/a"
      end

    retries_label =
      case retries_left do
        value when is_integer(value) and value >= 0 -> Integer.to_string(value)
        _ -> "?"
      end

    "#{reason}: retry in #{wait_label} (#{retries_label} retries left)."
  end

  defp format_failover(status) do
    action = read(status, :failover_action)
    provider = read(status, :provider)
    model = read(status, :model)
    reason = read(status, :reason) || "terminal retry"
    route = [provider, model] |> Enum.filter(&is_binary/1) |> Enum.join(":")

    case action do
      :retry_same ->
        "Failover policy: retrying same route after #{reason}."

      :fallback_model ->
        "Failover policy: switched model to #{route} after #{reason}."

      :fallback_provider ->
        "Failover policy: switched provider to #{route} after #{reason}."

      :stop ->
        "Failover policy exhausted after #{reason}."

      _ ->
        "Failover policy update after #{reason}."
    end
  end

  defp read(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) ||
      Map.get(map, Atom.to_string(key)) ||
      case safe_existing_atom(Atom.to_string(key)) do
        nil -> nil
        atom_key -> Map.get(map, atom_key)
      end
  end

  defp safe_existing_atom(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> nil
    end
  end
end
