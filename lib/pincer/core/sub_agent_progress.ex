defmodule Pincer.Core.SubAgentProgress do
  @moduledoc """
  Deterministic policy for sub-agent progress notifications.

  Converts blackboard updates into concise user-facing status messages while
  preventing repeated spam from duplicated progress events.
  """

  @type tracker_entry :: %{
          started?: boolean(),
          last_tool: String.t() | nil,
          terminal?: boolean()
        }

  @type tracker :: %{optional(String.t()) => tracker_entry()}

  @spec notifications([map()], tracker()) :: {[String.t()], tracker(), boolean()}
  def notifications(messages, tracker \\ %{})

  def notifications(messages, tracker) when is_list(messages) and is_map(tracker) do
    {notifications, tracker, needs_review?} =
      Enum.reduce(messages, {[], tracker, false}, fn message, {acc, current, review?} ->
        {agent_id, content} = parse_message(message)
        entry = Map.get(current, agent_id, default_entry())

        case classify(content) do
          {:started, _goal} ->
            if entry.started? or entry.terminal? do
              {acc, current, review?}
            else
              notification = "🚀 Sub-Agent #{agent_id} started."
              next = Map.put(current, agent_id, %{entry | started?: true})
              {[notification | acc], next, review?}
            end

          {:tool, tool} ->
            cond do
              entry.terminal? ->
                {acc, current, review?}

              not is_binary(tool) or tool == "" ->
                {acc, current, review?}

              entry.last_tool == tool ->
                {acc, current, review?}

              true ->
                notification = "⚙️ Sub-Agent #{agent_id} running: #{tool}."
                next = Map.put(current, agent_id, %{entry | last_tool: tool})
                {[notification | acc], next, review?}
            end

          {:finished, _result} ->
            if entry.terminal? do
              {acc, current, review?}
            else
              notification = "✅ Sub-Agent #{agent_id} finished."
              next = Map.put(current, agent_id, %{entry | terminal?: true, started?: true})
              {[notification | acc], next, review?}
            end

          {:failed, reason} ->
            if entry.terminal? do
              {acc, current, review?}
            else
              notification = "❌ Sub-Agent #{agent_id} failed: #{truncate_reason(reason)}"
              next = Map.put(current, agent_id, %{entry | terminal?: true, started?: true})
              {[notification | acc], next, review?}
            end

          :other ->
            {acc, current, true}
        end
      end)

    {Enum.reverse(notifications), tracker, needs_review?}
  end

  def notifications(_messages, tracker), do: {[], tracker, false}

  defp parse_message(message) when is_map(message) do
    agent_id =
      message_value(message, "agent_id")
      |> normalize_agent_id()

    content = message_value(message, "content")
    {agent_id, to_string(content || "")}
  end

  defp parse_message(_), do: {"unknown", ""}

  defp classify(content) do
    trimmed = String.trim(content)

    cond do
      String.starts_with?(trimmed, "Started with goal:") ->
        {:started, String.trim_leading(trimmed, "Started with goal:") |> String.trim()}

      String.starts_with?(trimmed, "Using tool:") ->
        {:tool, String.trim_leading(trimmed, "Using tool:") |> String.trim()}

      String.starts_with?(trimmed, "FINISHED:") ->
        {:finished, String.trim_leading(trimmed, "FINISHED:") |> String.trim()}

      String.starts_with?(trimmed, "FAILED:") ->
        {:failed, String.trim_leading(trimmed, "FAILED:") |> String.trim()}

      true ->
        :other
    end
  end

  defp truncate_reason(reason) do
    reason
    |> String.trim()
    |> case do
      "" -> "unknown reason"
      text when byte_size(text) <= 120 -> text
      text -> String.slice(text, 0, 117) <> "..."
    end
  end

  defp normalize_agent_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> "unknown"
      agent_id -> agent_id
    end
  end

  defp normalize_agent_id(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_agent_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_agent_id(_), do: "unknown"

  defp default_entry do
    %{started?: false, last_tool: nil, terminal?: false}
  end

  defp message_value(map, key) do
    Map.get(map, key) ||
      case safe_existing_atom(key) do
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
