defmodule Pincer.Core.ToolRuntime do
  @moduledoc """
  Risk-aware runtime wrapper for tool execution.

  Tools are classified into four risk classes and executed with class-specific
  timeout/cancellation constraints. Result summaries are sanitized per class.
  """

  @type risk_class :: :pure | :read | :guarded_write | :privileged
  @type exec_meta :: %{
          class: risk_class(),
          timeout_ms: pos_integer(),
          cancelled?: boolean()
        }

  @timeouts %{
    pure: 3_000,
    read: 8_000,
    guarded_write: 12_000,
    privileged: 15_000
  }

  @tool_classes %{
    "change_model" => :guarded_write,
    "channel_actions" => :guarded_write,
    "delete_cron_job" => :guarded_write,
    "dispatch_agent" => :privileged,
    "file_system" => :guarded_write,
    "get_code_skeleton" => :pure,
    "get_my_github_repos" => :read,
    "git_inspect" => :read,
    "github" => :privileged,
    "graph_history" => :read,
    "ingest_external_knowledge" => :guarded_write,
    "list_cron_jobs" => :read,
    "media" => :read,
    "read_blackboard" => :read,
    "record_learning" => :guarded_write,
    "safe_shell" => :privileged,
    "schedule_cron_job" => :guarded_write,
    "schedule_reminder" => :guarded_write,
    "schedule_timer_delay" => :guarded_write,
    "search_external_knowledge" => :read,
    "web_fetch" => :read,
    "web_search" => :read,
    "workflow" => :guarded_write,
    "browser" => :privileged
  }

  @spec classify(String.t()) :: {:ok, risk_class()} | {:error, :unclassified}
  def classify(tool_name) when is_binary(tool_name) do
    case Map.fetch(@tool_classes, tool_name) do
      {:ok, class} -> {:ok, class}
      :error -> {:error, :unclassified}
    end
  end

  @spec requires_approval?(String.t()) :: boolean()
  def requires_approval?(tool_name) when is_binary(tool_name) do
    case classify(tool_name) do
      {:ok, :privileged} -> true
      _ -> false
    end
  end

  @spec execute(String.t(), map(), map(), module(), keyword()) ::
          {:ok, any(), exec_meta()} | {:error, any(), exec_meta()}
  def execute(tool_name, args, context, registry, opts \\ [])
      when is_binary(tool_name) and is_map(args) and is_map(context) and is_list(opts) do
    class = Keyword.get(opts, :class, class_for(tool_name))
    timeout_ms = Keyword.get(opts, :timeout_ms, timeout_for(class))
    approval_granted? = Keyword.get(opts, :approval_granted, false)

    if class == :privileged and not approval_granted? and requires_approval?(tool_name) do
      {:error,
       {:approval_required,
        %{tool: tool_name, args: args, class: class, reason: :privileged_tool}},
       %{class: class, timeout_ms: timeout_ms, cancelled?: false}}
    else
      context_with_approval = Map.put(context, "approval_granted", approval_granted?)
      task =
        Task.async(fn ->
          registry.execute_tool(tool_name, args, context_with_approval)
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, value}} ->
          {:ok, value, %{class: class, timeout_ms: timeout_ms, cancelled?: false}}

        {:ok, {:error, reason}} ->
          {:error, reason, %{class: class, timeout_ms: timeout_ms, cancelled?: false}}

        {:ok, other} ->
          {:error, {:unexpected_tool_return, other},
           %{class: class, timeout_ms: timeout_ms, cancelled?: false}}

        nil ->
          {:error, :timeout, %{class: class, timeout_ms: timeout_ms, cancelled?: true}}
      end
    end
  end

  @spec sanitize_summary(String.t(), any()) :: String.t()
  def sanitize_summary(tool_name, result) when is_binary(tool_name) do
    class = class_for(tool_name)
    text = result_to_text(result)

    base =
      text
      |> strip_control_chars()
      |> String.trim()

    case class do
      :pure -> String.slice(base, 0, 240)
      :read -> String.slice(base, 0, 200)
      :guarded_write -> "[guarded] " <> String.slice(base, 0, 160)
      :privileged -> "[privileged] output redacted"
    end
  end

  defp class_for(tool_name) do
    case classify(tool_name) do
      {:ok, class} -> class
      {:error, :unclassified} -> :privileged
    end
  end

  defp timeout_for(class), do: Map.fetch!(@timeouts, class)

  defp result_to_text(parts) when is_list(parts), do: "list_result(items=#{length(parts)})"
  defp result_to_text(value) when is_binary(value), do: value
  defp result_to_text(value), do: inspect(value)

  defp strip_control_chars(text) when is_binary(text) do
    text
    |> String.replace(~r/\e\[[\d;]*m/, "")
    |> String.replace(~r/[\x00-\x1F\x7F]/u, " ")
  end
end
