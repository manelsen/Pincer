defmodule Pincer.Core.Session.AutoApproveTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Session.Server

  describe "approve_all/2" do
    test "enables auto-approval for the specified duration" do
      {:ok, _pid} = start_supervised_session("auto_approve_1")

      :ok = Server.approve_all("auto_approve_1", 600)

      {:ok, state} = Server.get_status("auto_approve_1")
      assert state.auto_approve_until != nil
      assert DateTime.compare(state.auto_approve_until, DateTime.utc_now()) == :gt
    end

    test "auto-approves pending request when enabled" do
      {:ok, pid} = start_supervised_session("auto_approve_2")

      # Enable auto-approve
      :ok = Server.approve_all("auto_approve_2", 600)

      # Simulate approval_required
      send(pid, {:approval_required, "call_abc", "safe_shell ls"})

      Process.sleep(100)

      {:ok, state} = Server.get_status("auto_approve_2")
      # Should be auto-approved, pending_approval should be nil
      assert state.pending_approval == nil
    end

    test "does not auto-approve when not enabled" do
      {:ok, pid} = start_supervised_session("auto_approve_3")

      # Do NOT enable auto-approve
      send(pid, {:approval_required, "call_def", "safe_shell ls"})

      Process.sleep(100)

      {:ok, state} = Server.get_status("auto_approve_3")
      assert state.pending_approval != nil
    end
  end

  defp start_supervised_session(id) do
    dir = System.tmp_dir!()
    File.mkdir_p!(Path.join(dir, id))

    {:ok, pid} =
      Server.start_link(
        session_id: id,
        root_agent_id: "test_agent",
        workspace_path: Path.join(dir, id),
        blackboard_scope: :global,
        llm_client: Pincer.MockLLM
      )

    Process.sleep(200)
    {:ok, pid}
  end
end
