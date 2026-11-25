defmodule Pincer.Core.Session.Blackboard do
  @moduledoc """
  Formatting, history ingestion, and pure LLM evaluation for session Blackboard updates.
  """

  alias PincerPorts.Structs.Usage
  alias Pincer.Core.SubAgentProgress
  alias Pincer.Ports.LLM

  @doc """
  Formats a single Blackboard journal message for system-prompt ingestion.

  Structured `:kind` is authoritative; legacy prefix checks remain only to keep
  older journal entries readable.
  """
  @spec format_message(map()) :: String.t()
  def format_message(msg) when is_map(msg) do
    project_id = Map.get(msg, :project_id)

    case blackboard_kind(msg) do
      :plan_generated ->
        plan = String.replace(msg.content, "PLAN_GENERATED:\n", "")

        "📋 **Suggested Project Plan (#{project_id})**:\n#{plan}\n\nTo proceed, use:\n`/project approve #{project_id}`\nOr modify with:\n`/project modify #{project_id} <new tasks>`"

      :error_diagnostic ->
        reason = String.replace(msg.content, "ERROR_DIAGNOSTIC: ", "")

        "❌ **CRITICAL PROJECT FAILURE (#{project_id})**\nThe agent exhausted all execution attempts.\n\n**Detected Reason:**\n`#{reason}`\n\nYou can:\n1. `/project resume #{project_id}` (Retry)\n2. `/project modify #{project_id} <plan>` (Change course)\n3. `/project stop #{project_id}`"

      _other ->
        "[#{project_id || "GLOBAL"}]: #{msg.content}"
    end
  end

  @doc """
  Applies a batch of Blackboard messages to `history` and `tracker`, returning
  updated history, tracker, user-facing progress notifications, and whether the
  session should review the update with the LLM.
  """
  @spec ingest([map()], SubAgentProgress.tracker(), [map()]) :: %{
          history: [map()],
          tracker: SubAgentProgress.tracker(),
          notifications: [String.t()],
          needs_review?: boolean()
        }
  def ingest(history, tracker, messages) do
    {notifications, new_tracker, needs_review?} =
      SubAgentProgress.notifications(messages, tracker)

    updates = Enum.map_join(messages, "\n\n", &format_message/1)

    system_msg = %{
      "role" => "system",
      "content" => "SYSTEM UPDATE (Blackboard):\n#{updates}"
    }

    %{
      history: history ++ [system_msg],
      tracker: new_tracker,
      notifications: notifications,
      needs_review?: needs_review?
    }
  end

  @doc """
  Evaluates whether a Blackboard update or bootstrap prompt warrants an
  unsolicited reply to the user, returning the outcome without side effects.
  """
  @spec evaluate_update([map()], map() | nil, keyword()) ::
          {:reply, String.t(), Usage.t() | nil} | :ignore | {:error, term()}
  def evaluate_update(history, model_override, opts \\ []) do
    llm_client = Keyword.get(opts, :llm_client, LLM)

    llm_opts =
      if is_map(model_override),
        do: [provider: model_override.provider, model: model_override.model],
        else: []

    case llm_client.chat_completion(history, llm_opts) do
      {:ok, %{"content" => resp}, usage} when is_binary(resp) ->
        if resp |> String.trim() |> String.upcase() == "IGNORE" do
          :ignore
        else
          {:reply, resp, Usage.normalize_optional(usage)}
        end

      {:ok, _message, _usage} ->
        :ignore

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp blackboard_kind(%{kind: kind}) when is_atom(kind) and not is_nil(kind), do: kind
  defp blackboard_kind(%{content: content}) when is_binary(content), do: legacy_kind(content)
  defp blackboard_kind(_msg), do: nil

  defp legacy_kind(content) do
    cond do
      String.contains?(content, "PLAN_GENERATED:") -> :plan_generated
      String.contains?(content, "ERROR_DIAGNOSTIC:") -> :error_diagnostic
      true -> nil
    end
  end
end
