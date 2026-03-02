defmodule Pincer.Adapters.Connectors.MCP.SidecarAudit do
  @moduledoc """
  Emits minimal audit trail for `skills_sidecar` MCP tool executions.
  """

  require Logger

  @event [:pincer, :mcp, :skills_sidecar, :tool_execution]

  @type status :: :ok | :error | :timeout | :blocked

  @spec status_from_result(any()) :: status()
  def status_from_result({:ok, _}), do: :ok
  def status_from_result({:error, :timeout}), do: :timeout
  def status_from_result({:error, {:timeout, _}}), do: :timeout
  def status_from_result({:error, :blocked}), do: :blocked
  def status_from_result({:error, {:blocked, _}}), do: :blocked
  def status_from_result({:error, _}), do: :error
  def status_from_result(_), do: :error

  @spec emit(String.t(), String.t(), non_neg_integer(), status(), map()) :: :ok
  def emit(skill_id, tool_name, duration_ms, status, metadata \\ %{})
      when is_binary(skill_id) and is_binary(tool_name) and is_map(metadata) do
    payload =
      metadata
      |> Map.put(:skill_id, skill_id)
      |> Map.put(:tool, tool_name)
      |> Map.put(:status, status)

    :telemetry.execute(@event, %{duration_ms: duration_ms}, payload)

    log_audit(skill_id, tool_name, duration_ms, status)
    :ok
  end

  defp log_audit(skill_id, tool_name, duration_ms, :ok) do
    Logger.info(
      "[MCP SIDECAR] skill=#{skill_id} tool=#{tool_name} status=ok duration_ms=#{duration_ms}"
    )
  end

  defp log_audit(skill_id, tool_name, duration_ms, status)
       when status in [:blocked, :timeout, :error] do
    Logger.warning(
      "[MCP SIDECAR] skill=#{skill_id} tool=#{tool_name} status=#{status} duration_ms=#{duration_ms}"
    )
  end
end
