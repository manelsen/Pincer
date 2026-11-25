defmodule Pincer.Channels.Shared.ProjectBridgeTest do
  use ExUnit.Case, async: false

  alias Pincer.Channels.Shared.ProjectBridge

  defmodule ProjectStub do
    def continue_if_collecting(session_id, text, opts) do
      notify({:continue_if_collecting, session_id, text, opts})
      Process.get(:project_continue_result, :not_handled)
    end

    def on_agent_response(session_id, opts) do
      notify({:on_agent_response, session_id, opts})
      :ok
    end

    def on_agent_error(session_id, opts) do
      notify({:on_agent_error, session_id, opts})
      :ok
    end

    def kickoff(session_id) do
      notify({:kickoff, session_id})
      Process.get(:project_kickoff_result, :not_ready)
    end

    defp notify(msg) do
      if pid = Process.get(:project_bridge_test_pid), do: send(pid, msg)
    end
  end

  defmodule SessionStub do
    def process_input(session_id, prompt) do
      if pid = Process.get(:project_bridge_test_pid),
        do: send(pid, {:session_process_input, session_id, prompt})

      Process.get(:project_dispatch_result, {:ok, :started})
    end
  end

  setup do
    Process.put(:project_bridge_test_pid, self())

    saved_env = %{
      project_adapter: Application.fetch_env(:pincer, :project_adapter),
      session_adapter: Application.fetch_env(:pincer, :session_adapter)
    }

    Application.put_env(:pincer, :project_adapter, ProjectStub)
    Application.put_env(:pincer, :session_adapter, SessionStub)

    on_exit(fn ->
      Process.delete(:project_bridge_test_pid)
      Process.delete(:project_continue_result)
      Process.delete(:project_kickoff_result)
      Process.delete(:project_dispatch_result)

      Enum.each(saved_env, fn
        {key, {:ok, val}} -> Application.put_env(:pincer, key, val)
        {key, :error} -> Application.delete_env(:pincer, key)
      end)
    end)

    :ok
  end

  test "continue/3 delegates to PincerPorts.Project.continue_if_collecting/3" do
    Process.put(:project_continue_result, {:handled, "Next question"})

    assert {:handled, "Next question"} =
             ProjectBridge.continue("telegram_42", "software", has_attachments: false)

    assert_received {:continue_if_collecting, "telegram_42", "software", [has_attachments: false]}
  end

  test "on_agent_response/2 and on_agent_error/2 accept callback function or keyword opts" do
    send_fn = fn text -> send(self(), {:sent, text}) end

    assert :ok = ProjectBridge.on_agent_response("discord_1", send_fn)
    assert_received {:on_agent_response, "discord_1", [send_message: ^send_fn]}

    assert :ok = ProjectBridge.on_agent_error("discord_1", send_message: send_fn)
    assert_received {:on_agent_error, "discord_1", [send_message: ^send_fn]}
  end

  test "kickoff/2 ensures session/worker, sends runner status, and dispatches prompt" do
    Process.put(
      :project_kickoff_result,
      {:ok, %{status_message: "Started task 1", prompt: "Build feature"}}
    )

    assert :ok =
             ProjectBridge.kickoff("telegram_42",
               ensure_session: fn ->
                 send(self(), :ensured_session)
                 :ok
               end,
               ensure_worker: fn ->
                 send(self(), :ensured_worker)
                 {:error, {:already_started, self()}}
               end,
               send_message: fn text -> send(self(), {:sent, text}) end
             )

    assert_received {:kickoff, "telegram_42"}
    assert_received :ensured_session
    assert_received :ensured_worker
    assert_received {:sent, "Project Runner: Started task 1"}
    assert_received {:session_process_input, "telegram_42", "Build feature"}
  end

  test "kickoff/2 supports custom dispatch and aborts cleanly on ensure failure" do
    Process.put(
      :project_kickoff_result,
      {:ok, %{status_message: "Started", prompt: "Run"}}
    )

    assert :ok =
             ProjectBridge.kickoff("whatsapp_1",
               ensure_session: fn -> {:error, :session_failed} end,
               ensure_worker: fn -> flunk("must not start worker when session failed") end,
               send_message: fn _ -> flunk("must not send when ensure failed") end,
               on_start_error: fn reason -> send(self(), {:start_err, reason}) end,
               log_tag: "WHATSAPP"
             )

    assert_received {:start_err, :session_failed}

    Process.put(:project_dispatch_result, {:error, :busy})

    assert :ok =
             ProjectBridge.kickoff("whatsapp_1",
               ensure_session: fn -> :ok end,
               ensure_worker: fn -> :ok end,
               send_message: fn text -> send(self(), {:sent, text}) end,
               dispatch: fn prompt ->
                 send(self(), {:custom_dispatch, prompt})
                 {:error, :busy}
               end,
               log_tag: "WHATSAPP"
             )

    assert_received {:sent, "Project Runner: Started"}
    assert_received {:custom_dispatch, "Run"}
  end

  test "kickoff/2 is a no-op for non-ready statuses" do
    for status <- [:not_ready, :already_started, :completed] do
      Process.put(:project_kickoff_result, status)

      assert :ok =
               ProjectBridge.kickoff("telegram_1",
                 send_message: fn _ -> flunk("must not send on #{status}") end
               )
    end
  end
end
