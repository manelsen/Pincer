defmodule Pincer.Core.Project.DiagnosticTest do
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Core.Project.Server
  alias Pincer.Core.Orchestration.Blackboard

  setup :set_mox_from_context

  setup do
    case Process.whereis(Blackboard) do
      nil -> Blackboard.start_link([])
      _ -> :ok
    end

    Blackboard.reset()
    :ok
  end

  test "Generates ERROR_DIAGNOSTIC when max_retries is reached" do
    # 1. Mock do Arquiteto
    Pincer.LLM.ClientMock
    |> stub(:chat_completion, fn _msgs, _model, _config, _tools ->
      {:ok, %{"content" => "Coder: Fail this task"}}
    end)

    id = "p-fail-123"
    # Iniciamos com max_retries: 1 para o teste ser rápido
    {:ok, _pid} =
      Server.start_link(
        id: id,
        session_id: "s-diag",
        objective: "Diagnostic test",
        max_retries: 1
      )

    # 2. Aguarda planejamento e aprova
    wait_for_status(id, :awaiting_approval)
    Server.approve(id)

    # 3. Forçamos a falha do Executor enviando a mensagem de erro diretamente
    # Espera o worker subir
    Process.sleep(100)

    # Resolvemos o PID da tupla :via antes de dar o send
    target_pid = GenServer.whereis(Pincer.Core.Project.Registry.via_tuple(id))
    send(target_pid, {:executor_failed, :rate_limit_exceeded})

    # 4. Verificamos se o Blackboard recebeu o diagnóstico
    wait_for_status(id, :error)

    {messages, _} = Blackboard.fetch_new(0)

    diagnostic_msg =
      Enum.find(messages, fn m -> String.contains?(m.content, "ERROR_DIAGNOSTIC") end)

    assert diagnostic_msg != nil
    assert diagnostic_msg.project_id == id
    # Verificamos que o diagnóstico contém o motivo da falha (seja o forçado ou o real do Mox)
    assert String.contains?(diagnostic_msg.content, "Task failed after")

    IO.puts("\n✅ Diagnóstico gerado com sucesso:\n#{diagnostic_msg.content}")
  end

  defp wait_for_status(id, target_status, attempts \\ 20) do
    if attempts == 0 do
      flunk("Timeout waiting for status #{target_status}")
    else
      case Server.get_status(id) do
        {:ok, %{status: ^target_status}} ->
          :ok

        _ ->
          Process.sleep(100)
          wait_for_status(id, target_status, attempts - 1)
      end
    end
  end
end
