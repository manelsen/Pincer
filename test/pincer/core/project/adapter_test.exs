defmodule Pincer.Core.Project.AdapterTest do
  @moduledoc """
  Verifies the `Pincer.Ports.Project` port contract against an empty
  orchestrator state.

  Runs synchronously because the orchestrator and the port keep state in
  global ETS / application env.
  """
  use ExUnit.Case, async: false

  alias Pincer.Core.Project.Adapter
  alias Pincer.Core.ProjectOrchestrator

  # No wizard state is ever created for these ids, so every lookup misses.
  @unknown_session "project-adapter-test-unknown"
  @dispatch_session "project-adapter-test-dispatch"

  defmodule Stub do
    @behaviour PincerPorts.Project

    def handle_command(command, args, session_id),
      do: {:handle_command, command, args, session_id}

    def continue_if_collecting(session_id, text, opts),
      do: {:continue_if_collecting, session_id, text, opts}

    def kickoff(session_id), do: {:kickoff, session_id}
    def kanban(session_id), do: {:kanban, session_id}
    def project(session_id, seed), do: {:project, session_id, seed}
    def phase(session_id), do: {:phase, session_id}
    def on_agent_response(session_id, opts), do: {:on_agent_response, session_id, opts}
    def on_agent_error(session_id, opts), do: {:on_agent_error, session_id, opts}
  end

  setup do
    ProjectOrchestrator.reset_all()
    on_exit(fn -> ProjectOrchestrator.reset_all() end)
    :ok
  end

  test "implements the Project behaviour and its callbacks" do
    behaviours =
      Adapter.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert PincerPorts.Project in behaviours

    for {fun, arity} <- PincerPorts.Project.behaviour_info(:callbacks) do
      assert function_exported?(Adapter, fun, arity),
             "Adapter does not implement #{fun}/#{arity}"
    end
  end

  test "the test double covers every port callback" do
    for {fun, arity} <- PincerPorts.Project.behaviour_info(:callbacks) do
      assert function_exported?(Stub, fun, arity),
             "Stub does not implement #{fun}/#{arity} - update it with the port"
    end
  end

  describe "with no project state" do
    test "phase/1 reports :unknown for a session without a project" do
      assert Adapter.phase(@unknown_session) == :unknown
    end

    test "kanban/1 returns the unavailable hint" do
      assert Adapter.kanban(@unknown_session) ==
               "Kanban unavailable for this session. Use /project to start the wizard."
    end

    test "continue_if_collecting/3 does not handle blank text" do
      assert Adapter.continue_if_collecting(@unknown_session, "", []) == :not_handled
    end

    test "on_agent_response/2 is a no-op that never calls the sender" do
      assert Adapter.on_agent_response(@unknown_session, send_message: fn _ -> :ok end) == :ok
    end

    test "the stub sender is not invoked when there is nothing to deliver" do
      parent = self()
      sender = fn message -> send(parent, {:sent, message}) end

      assert Adapter.on_agent_response(@unknown_session, send_message: sender) == :ok
      refute_received {:sent, _}
    end
  end

  describe "port dispatch" do
    setup do
      previous = Application.get_env(:pincer, :project_adapter)
      Application.put_env(:pincer, :project_adapter, Stub)
      on_exit(fn -> restore(previous) end)
      :ok
    end

    test "routes every operation through the configured adapter" do
      alias Pincer.Ports.Project

      sender = fn _ -> :ok end

      assert Project.handle_command(:status, nil, @dispatch_session) ==
               {:handle_command, :status, nil, @dispatch_session}

      assert Project.continue_if_collecting(@dispatch_session, "hi") ==
               {:continue_if_collecting, @dispatch_session, "hi", []}

      assert Project.continue_if_collecting(@dispatch_session, "hi", has_attachments: true) ==
               {:continue_if_collecting, @dispatch_session, "hi", [has_attachments: true]}

      assert Project.kickoff(@dispatch_session) == {:kickoff, @dispatch_session}
      assert Project.kanban(@dispatch_session) == {:kanban, @dispatch_session}
      assert Project.project(@dispatch_session) == {:project, @dispatch_session, nil}
      assert Project.project(@dispatch_session, "seed") == {:project, @dispatch_session, "seed"}
      assert Project.phase(@dispatch_session) == {:phase, @dispatch_session}

      assert Project.on_agent_response(@dispatch_session) ==
               {:on_agent_response, @dispatch_session, []}

      assert Project.on_agent_response(@dispatch_session, send_message: sender) ==
               {:on_agent_response, @dispatch_session, [send_message: sender]}

      assert Project.on_agent_error(@dispatch_session) == {:on_agent_error, @dispatch_session, []}

      assert Project.on_agent_error(@dispatch_session, send_message: sender) ==
               {:on_agent_error, @dispatch_session, [send_message: sender]}
    end
  end

  defp restore(nil), do: Application.delete_env(:pincer, :project_adapter)
  defp restore(value), do: Application.put_env(:pincer, :project_adapter, value)
end
