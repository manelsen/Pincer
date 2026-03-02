defmodule Pincer.Project.HardeningTest do
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Project.Server
  alias Pincer.Orchestration.Blackboard

  # Usamos stub global para que os processos asíncronos (handle_continue)
  # consigam chamar o mock sem erro de ownership.
  setup :set_mox_from_context
  
  setup do
    Pincer.LLM.ClientMock
    |> stub(:chat_completion, fn _msgs, _model, _config, _tools -> 
      {:ok, %{"content" => "Architect: Spec\nTester: RED\nCoder: GREEN"}}
    end)

    case Process.whereis(Blackboard) do
      nil -> Blackboard.start_link([])
      _ -> :ok
    end
    :ok
  end

  @doc "BLINDAGEM 1: Stop deve matar o worker zumbi"
  test "stop/1 terminates the worker process immediately" do
    id = "p-zombie-test"
    {:ok, pid} = Server.start_link(id: id, session_id: "s1", objective: "Heavy Task")
    
    wait_for_status(id, :awaiting_approval)
    Server.approve(id)
    
    # Busy wait pelo worker subir
    worker_pid = wait_for_worker(id)
    assert Process.alive?(worker_pid)

    # Para o projeto
    Server.stop(id)
    Process.sleep(100)

    refute Process.alive?(pid)
    # BLINDAGEM: O worker também deve ter morrido via terminate/2
    refute Process.alive?(worker_pid)
  end

  @doc "BLINDAGEM 3: Impedir execução sem aprovação"
  test "execution logic is ignored if status is not :running" do
    id = "p-bypass-test"
    {:ok, pid} = Server.start_link(id: id, session_id: "s1", objective: "Forbidden task")
    
    wait_for_status(id, :awaiting_approval)
    
    # Tentamos forçar o handle_info de execução enviando mensagem direta ao processo
    send(pid, :execute_next)
    Process.sleep(100)
    
    {:ok, state} = Server.get_status(id)
    assert state.status == :awaiting_approval
    assert state.worker_pid == nil
  end

  @doc "BLINDAGEM 5: Respeitar limite de retries"
  test "project enters :error state after max_retries" do
    id = "p-retry-test"
    # max_retries: 1 para o teste ser rápido
    {:ok, _pid} = Server.start_link(id: id, session_id: "s1", objective: "Fail task", max_retries: 1)
    
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

  defp wait_for_status(id, target_status, attempts \\ 20) do
    if attempts == 0 do
      flunk("Timeout waiting for status #{target_status}")
    else
      case Server.get_status(id) do
        {:ok, %{status: ^target_status}} -> :ok
        _ -> 
          Process.sleep(50)
          wait_for_status(id, target_status, attempts - 1)
      end
    end
  end

  defp wait_for_worker(id, attempts \\ 20) do
    if attempts == 0 do
      flunk("Timeout waiting for worker process")
    else
      case Server.get_status(id) do
        {:ok, %{worker_pid: pid}} when is_pid(pid) -> pid
        _ -> 
          Process.sleep(50)
          wait_for_worker(id, attempts - 1)
      end
    end
  end
end
