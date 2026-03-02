defmodule Pincer.CLI.Test do
  use ExUnit.Case
  doctest Pincer.CLI

  # Teste de Unidade Pura (Input Parsing)
  describe "process_command/1" do
    test "retorna :quit para comandos de saída" do
      assert Pincer.CLI.process_command("/quit") == :quit
      assert Pincer.CLI.process_command("/q") == :quit
    end

    test "retorna :clear para limpeza" do
      assert Pincer.CLI.process_command("/clear") == :clear
    end

    test "retorna {:send, msg} para texto normal" do
      assert Pincer.CLI.process_command("Olá Pincer") == {:send, "Olá Pincer"}
    end

    test "retorna comandos de histórico" do
      assert Pincer.CLI.process_command("/history") == {:history, 10}
      assert Pincer.CLI.process_command("/history 3") == {:history, 3}
      assert Pincer.CLI.process_command("/history clear") == :history_clear
      assert Pincer.CLI.process_command("/history nope") == {:history, 10}
    end
  end

  # Teste de Integração (Mock Session)
  # Este teste verifica se o CLI sabe enviar mensagens para o processo correto
  describe "integração com sessão" do
    test "envia mensagem para o servidor de sessão" do
      # Cria um processo fake para simular o Session.Server
      session_pid =
        spawn(fn ->
          receive do
            {:"$gen_call", from, {:process_input, "Teste"}} ->
              GenServer.reply(from, {:ok, :started})
          end
        end)

      # Como o CLI real usa Registry, aqui apenas testamos a lógica de envio isolada
      # Se a função send_message existir e funcionar
      assert Pincer.CLI.send_message(session_pid, "Teste") == :ok
    end
  end
end
