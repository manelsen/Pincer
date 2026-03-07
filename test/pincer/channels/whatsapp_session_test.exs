defmodule Pincer.Channels.WhatsAppSessionTest do
  use ExUnit.Case, async: false

  alias Pincer.Channels.WhatsApp
  alias Pincer.Channels.WhatsApp.Session
  alias Pincer.Core.ProjectOrchestrator
  alias Pincer.Core.ProjectRouter

  defmodule FakeBridge do
    @behaviour Pincer.Channels.WhatsApp.Bridge
    use Agent

    @impl true
    def start_link(opts) do
      owner = Keyword.fetch!(opts, :owner)
      config = Keyword.get(opts, :config, %{})
      test_pid = config["test_pid"] || config[:test_pid]

      Agent.start_link(fn ->
        %{
          owner: owner,
          test_pid: test_pid
        }
      end)
    end

    @impl true
    def send_message(pid, chat_id, text) do
      test_pid = Agent.get(pid, & &1.test_pid)

      if is_pid(test_pid) do
        send(test_pid, {:bridge_send, chat_id, text})
      end

      :ok
    end
  end

  defmodule ProjectGitStub do
    @moduledoc false

    def ensure_branch(name) do
      {:ok, %{name: name, status: :existing, source_branch: "main", repo_path: File.cwd!()}}
    end
  end

  setup do
    previous_project_git = Application.get_env(:pincer, :project_git)
    previous_retry_limit = Application.get_env(:pincer, :project_task_retry_limit)

    Application.put_env(:pincer, :project_git, ProjectGitStub)
    Application.put_env(:pincer, :project_task_retry_limit, 0)

    stop_channel()

    {:ok, _channel_pid} =
      WhatsApp.start_link(%{
        "bridge_module" => FakeBridge,
        "test_pid" => self()
      })

    on_exit(fn ->
      case previous_project_git do
        nil -> Application.delete_env(:pincer, :project_git)
        value -> Application.put_env(:pincer, :project_git, value)
      end

      case previous_retry_limit do
        nil -> Application.delete_env(:pincer, :project_task_retry_limit)
        value -> Application.put_env(:pincer, :project_task_retry_limit, value)
      end

      ProjectOrchestrator.reset_all()
      stop_channel()
    end)

    :ok
  end

  test "agent_response is delivered to whatsapp chat" do
    chat_id = "551199333333"
    {:ok, pid} = Session.start_link(chat_id)

    send(pid, {:agent_response, "Only final", nil})

    assert_receive {:bridge_send, ^chat_id, "Only final"}, 500
  end

  test "worker rebinds to whatsapp_main session and receives pubsub events" do
    chat_id = "551199444444"
    {:ok, pid} = Session.start_link(chat_id)

    assert {:error, {:already_started, ^pid}} =
             Session.ensure_started(chat_id, "whatsapp_main")

    Process.sleep(50)

    Pincer.Infra.PubSub.broadcast(
      "session:whatsapp_main",
      {:agent_response, "Main scope reply", nil}
    )

    assert_receive {:bridge_send, ^chat_id, "Main scope reply"}, 500
  end

  test "agent_status is delivered as user-visible message" do
    chat_id = "551199555555"
    {:ok, pid} = Session.start_link(chat_id)

    send(pid, {:agent_status, "Status update"})

    assert_receive {:bridge_send, ^chat_id, "Status update"}, 500
  end

  test "agent_error pauses project task and unlocks kanban when retry budget is zero" do
    chat_id = "551199666666"
    {:ok, pid} = Session.start_link(chat_id)

    session_id = "whatsapp_#{chat_id}"
    assert ProjectRouter.project(session_id) =~ "Project Manager"
    assert {:handled, _} = ProjectRouter.continue_if_collecting(session_id, "Pesquisa de mercado")
    assert {:handled, _} = ProjectRouter.continue_if_collecting(session_id, "nao-software")
    assert {:handled, _} = ProjectRouter.continue_if_collecting(session_id, "Brasil, internet")
    assert {:handled, _} = ProjectRouter.continue_if_collecting(session_id, "Relatorio final")
    assert {:ok, _kickoff} = ProjectRouter.kickoff(session_id)

    send(pid, {:agent_error, "Tive um erro tecnico temporario."})

    assert_receive {:bridge_send, ^chat_id, "Agent error: Tive um erro tecnico temporario."}, 500
    assert_receive {:bridge_send, ^chat_id, paused_notice}, 500
    assert paused_notice =~ "Project Runner: Task paused after 0 retries"

    board = ProjectRouter.kanban(session_id)
    assert board =~ "Done: 0 | In Progress: 0 | Pending: 5"
  end

  defp stop_channel do
    case Process.whereis(Pincer.Channels.WhatsApp) do
      nil ->
        :ok

      pid ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        else
          :ok
        end
    end
  end
end
