defmodule Pincer.Connectors.MCP.SidecarAuditTest do
  use ExUnit.Case, async: true

  alias Pincer.Connectors.MCP.SidecarAudit

  @event [:pincer, :mcp, :skills_sidecar, :tool_execution]

  describe "status_from_result/1" do
    test "maps successful and failure tuples to stable statuses" do
      assert SidecarAudit.status_from_result({:ok, "done"}) == :ok
      assert SidecarAudit.status_from_result({:error, :timeout}) == :timeout
      assert SidecarAudit.status_from_result({:error, {:timeout, :killed}}) == :timeout
      assert SidecarAudit.status_from_result({:error, :blocked}) == :blocked
      assert SidecarAudit.status_from_result({:error, :tool_failed}) == :error
    end
  end

  describe "emit/5" do
    test "emits telemetry event with minimum metadata contract" do
      parent = self()
      handler_id = "pincer-sidecar-audit-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          @event,
          fn event, measurements, metadata, _config ->
            send(parent, {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok =
               SidecarAudit.emit("skills_sidecar", "run_skill", 21, :ok, %{skill_version: "v1"})

      assert_receive {:telemetry_event, @event, %{duration_ms: 21},
                      %{
                        skill_id: "skills_sidecar",
                        tool: "run_skill",
                        status: :ok,
                        skill_version: "v1"
                      }}
    end
  end
end
