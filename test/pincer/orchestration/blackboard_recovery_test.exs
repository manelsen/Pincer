defmodule Pincer.Orchestration.BlackboardRecoveryTest do
  use ExUnit.Case, async: false
  alias Pincer.Orchestration.Blackboard

  setup do
    # Limpa o arquivo de journal para o teste
    File.rm("memory/blackboard.journal")
    
    case Process.whereis(Blackboard) do
      nil -> Blackboard.start_link([])
      _ -> :ok
    end
    :ok
  end

  test "Transparently retrieves pruned messages from disk" do
    # 1. Postamos 10 mensagens
    for i <- 1..10 do
      Blackboard.post_direct(i, "agent", "Msg #{i}", "p1")
    end

    # Aguarda o Journaler processar
    Blackboard.wait_for_journal()

    # 2. Forçamos a limpeza do Cache RAM (ETS)
    # Deletamos as primeiras 5 mensagens do ETS
    for i <- 1..5 do
      :ets.delete(:pincer_blackboard, i)
    end

    # Verifica que o cache RAM está incompleto
    assert :ets.info(:pincer_blackboard, :size) == 5

    # 3. Solicitamos mensagens desde o ID 0 (que foram deletadas da RAM)
    {messages, last_id} = Blackboard.fetch_new(0, 10)

    # O sistema deve ter buscado as 5 primeiras no disco e as outras 5 na RAM
    assert length(messages) == 10
    assert Enum.at(messages, 0).id == 1
    assert Enum.at(messages, 9).id == 10
    assert last_id == 10

    IO.puts("
✅ Recuperação de disco transparente validada!")
  end
end
