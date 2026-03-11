defmodule Pincer.Core.SubAgentProgress do
  @moduledoc """
  Deterministic policy for sub-agent progress notifications.

  Converts blackboard updates into concise user-facing status messages while
  preventing repeated spam from duplicated progress events.
  """

  @type tracker_entry :: %{
          started?: boolean(),
          goal: String.t() | nil,
          state: :running | :finished | :failed,
          last_tool: String.t() | nil,
          last_status: String.t() | nil,
          result: String.t() | nil,
          failure: String.t() | nil,
          terminal?: boolean()
        }

  @type tracker :: %{optional(String.t()) => tracker_entry()}

  @type progress_event :: %{
          required(:agent_id) => String.t(),
          required(:kind) => :started | :tool | :llm_status | :finished | :failed,
          optional(:goal) => String.t(),
          optional(:tool) => String.t(),
          optional(:status) => String.t(),
          optional(:result) => String.t(),
          optional(:reason) => String.t()
        }

  @spec apply_event(tracker(), progress_event()) :: tracker()
  def apply_event(tracker, event) when is_map(tracker) and is_map(event) do
    agent_id =
      event
      |> Map.get(:agent_id) ||
        Map.get(event, "agent_id")
        |> normalize_agent_id()

    entry = Map.get(tracker, agent_id, default_entry())

    next =
      case Map.get(event, :kind) || Map.get(event, "kind") do
        :started ->
          %{
            entry
            | goal: normalize_text(Map.get(event, :goal) || Map.get(event, "goal")) || entry.goal,
              started?: true,
              state: :running
          }

        :tool ->
          tool = normalize_text(Map.get(event, :tool) || Map.get(event, "tool"))

          if tool do
            %{entry | last_tool: tool, started?: true, state: running_state(entry)}
          else
            entry
          end

        :llm_status ->
          status = normalize_text(Map.get(event, :status) || Map.get(event, "status"))

          if status do
            %{entry | last_status: status, started?: true, state: running_state(entry)}
          else
            entry
          end

        :finished ->
          %{
            entry
            | started?: true,
              terminal?: true,
              state: :finished,
              result: normalize_text(Map.get(event, :result) || Map.get(event, "result"))
          }

        :failed ->
          %{
            entry
            | started?: true,
              terminal?: true,
              state: :failed,
              failure:
                truncate_reason(
                  normalize_text(Map.get(event, :reason) || Map.get(event, "reason")) || ""
                )
          }

        _ ->
          entry
      end

    Map.put(tracker, agent_id, next)
  end

  def apply_event(tracker, _event), do: tracker

  @spec render_dashboard(tracker()) :: String.t() | nil
  def render_dashboard(tracker) when is_map(tracker) do
    entries =
      tracker
      |> Enum.sort_by(fn {agent_id, entry} ->
        {state_rank(entry.state), agent_id}
      end)
      |> Enum.map(fn {agent_id, entry} -> render_entry(agent_id, entry) end)

    case entries do
      [] -> nil
      _ -> ["**Sub-Agent Checklist**" | entries] |> Enum.join("\n\n")
    end
  end

  def render_dashboard(_), do: nil

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

          {:llm_status, status} ->
            cond do
              entry.terminal? ->
                {acc, current, review?}

              not is_binary(status) or status == "" ->
                {acc, current, review?}

              entry.last_status == status ->
                {acc, current, review?}

              true ->
                notification = "🧠 Sub-Agent #{agent_id}: #{status}"
                next = Map.put(current, agent_id, %{entry | last_status: status})
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

      String.starts_with?(trimmed, "LLM_STATUS:") ->
        {:llm_status, String.trim_leading(trimmed, "LLM_STATUS:") |> String.trim()}

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
    %{
      started?: false,
      goal: nil,
      state: :running,
      last_tool: nil,
      last_status: nil,
      result: nil,
      failure: nil,
      terminal?: false
    }
  end

  defp render_entry(agent_id, entry) do
    lines =
      [
        "`#{agent_id}`",
        "Goal: #{entry.goal || "pending"}",
        "☑ Started",
        render_tool(entry),
        render_runtime_status(entry),
        render_terminal(entry)
      ]
      |> Enum.filter(&is_binary/1)

    Enum.join(lines, "\n")
  end

  defp render_tool(%{last_tool: nil}), do: "☐ Last tool: pending"
  defp render_tool(%{last_tool: tool}), do: "☑ Last tool: `#{tool}`"

  defp render_runtime_status(%{last_status: nil}), do: "☐ Runtime status: quiet"
  defp render_runtime_status(%{last_status: status}), do: "☑ Runtime status: #{status}"

  defp render_terminal(%{state: :finished, result: result}) do
    "☑ Finished" <> render_terminal_detail("Result", result)
  end

  defp render_terminal(%{state: :failed, failure: failure}) do
    "☒ Failed: #{failure || "unknown reason"}"
  end

  defp render_terminal(_entry), do: "☐ Finished"

  defp render_terminal_detail(_label, nil), do: ""
  defp render_terminal_detail(_label, ""), do: ""
  defp render_terminal_detail(label, value), do: "\n#{label}: #{value}"

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp normalize_text(_), do: nil

  defp running_state(%{terminal?: true, state: state}), do: state
  defp running_state(_entry), do: :running

  defp state_rank(:running), do: 0
  defp state_rank(:failed), do: 1
  defp state_rank(:finished), do: 2
  defp state_rank(_), do: 3

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
