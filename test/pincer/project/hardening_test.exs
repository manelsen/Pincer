defmodule Pincer.Core.Project.HardeningTest do
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Core.Project.Server
  alias Pincer.Core.Orchestration.Blackboard
  alias Pincer.Test.ProjectServer
  alias Pincer.Test.Support.LLMHelpers
  alias Pincer.Test.Support.SyncHelpers

  # Usamos stub global para que os processos asíncronos (handle_continue)
  # consigam chamar o mock sem erro de ownership.
  setup :set_mox_from_context

  setup do
    LLMHelpers.put_providers!(
      %{"test" => LLMHelpers.mock_provider_config()},
      default: "test"
    )

    Pincer.LLM.ClientMock
    |> stub(:chat_completion, fn _msgs, _model, _config, _tools ->
      {:ok, %{"content" => "Architect: Spec\nTester: RED\nCoder: GREEN"}}
    end)
    |> stub(:stream_completion, fn _msgs, _model, _config, _tools ->
      {:ok, [%{"choices" => [%{"delta" => %{"content" => "Coder: Done"}}]}]}
    end)

    case Process.whereis(Blackboard) do
      nil -> Blackboard.start_link([])
      _ -> :ok
    end

    :ok
  end

  @doc "BLINDAGEM 1: Stop deve matar o worker zumbi"
  test "stop/1 terminates the worker process immediately" do
    id = "p-zombie-#{System.unique_integer([:positive])}"
    {:ok, pid} = Server.start_link(id: id, session_id: "s1", objective: "Heavy Task")
    on_exit(fn -> ProjectServer.stop(pid) end)

    wait_for_status(id, :awaiting_approval)
    Server.approve(id)

    # Busy wait pelo worker subir
    worker_pid = wait_for_worker(id)
    assert Process.alive?(worker_pid)

    # Para o projeto
    Server.stop(id)

    assert wait_until(fn -> Process.alive?(pid) end) == :gone
    # BLINDAGEM: O worker também deve ter morrido via terminate/2
    assert wait_until(fn -> Process.alive?(worker_pid) end) == :gone
  end

  @doc "BLINDAGEM 3: Impedir execução sem aprovação"
  test "execution logic is ignored if status is not :running" do
    id = "p-bypass-#{System.unique_integer([:positive])}"
    {:ok, pid} = Server.start_link(id: id, session_id: "s1", objective: "Forbidden task")
    on_exit(fn -> ProjectServer.stop(pid) end)

    wait_for_status(id, :awaiting_approval)

    # Tentamos forçar o handle_info de execução enviando mensagem direta ao processo
    send(pid, :execute_next)
    # The server replies only after processing the message, so this call proves
    # `:execute_next` was handled before we read the state.
    _ = Server.get_status(id)

    {:ok, state} = Server.get_status(id)
    assert state.status == :awaiting_approval
    assert state.worker_pid == nil
  end

  @doc "BLINDAGEM 5: Respeitar limite de retries"
  test "project enters :error state after max_retries" do
    id = "p-retry-#{System.unique_integer([:positive])}"
    # max_retries: 1 para o teste ser rápido
    {:ok, _pid} =
      Server.start_link(id: id, session_id: "s1", objective: "Fail task", max_retries: 1)

    wait_for_status(id, :awaiting_approval)
    Server.approve(id)

    # Matamos o worker para forçar retries
    worker_pid = wait_for_worker(id)
    Process.exit(worker_pid, :kill)

    wait_for_status(id, :error)
    {:ok, state} = Server.get_status(id)
    assert state.status == :error
    assert state.retry_count == 1
  end

  # --- Helpers ---

  defp wait_for_status(id, target_status) do
    SyncHelpers.eventually(
      fn -> match?({:ok, %{status: ^target_status}}, Server.get_status(id)) end,
      timeout: 1_000,
      interval: 10,
      message: "Timeout waiting for status #{target_status}"
    )
  end

  defp wait_until(predicate) do
    SyncHelpers.eventually(
      fn -> not predicate.() end,
      timeout: 1_000,
      interval: 10
    )

    :gone
  end

  defp wait_for_worker(id) do
    SyncHelpers.eventually(
      fn ->
        case Server.get_status(id) do
          {:ok, %{worker_pid: pid}} when is_pid(pid) -> pid
          _ -> nil
        end
      end,
      timeout: 1_000,
      interval: 10,
      message: "Timeout waiting for worker process"
    )
  end
end
