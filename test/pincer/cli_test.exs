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

    test "retorna :status para consulta de estado da sessão" do
      assert Pincer.CLI.process_command("/status") == :status
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

  describe "backend_name/0" do
    setup do
      previous = Application.get_env(:pincer, :cli_channel_adapter)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:pincer, :cli_channel_adapter)
        else
          Application.put_env(:pincer, :cli_channel_adapter, previous)
        end
      end)

      :ok
    end

    test "resolves cli adapter from plugin manifest by default" do
      Application.delete_env(:pincer, :cli_channel_adapter)
      assert Pincer.CLI.backend_name() == Pincer.Channels.CLI
    end

    test "prefers :cli_channel_adapter application override when set" do
      Application.put_env(:pincer, :cli_channel_adapter, Pincer.CLI.Test.FakeBackend)
      assert Pincer.CLI.backend_name() == Pincer.CLI.Test.FakeBackend
    end
  end

  describe "ANSI styling" do
    setup do
      previous = Application.get_env(:elixir, :ansi_enabled)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:elixir, :ansi_enabled)
        else
          Application.put_env(:elixir, :ansi_enabled, previous)
        end
      end)

      :ok
    end

    test "delegates styling to Pincer.Utils.ANSI without inline IO.ANSI calls" do
      source = File.read!(Path.expand("../../lib/pincer/cli.ex", __DIR__))
      refute source =~ "IO.ANSI"

      Application.put_env(:elixir, :ansi_enabled, true)
      assert Pincer.CLI.prompt_label() == "\e[36m[User]: \e[0m"

      Application.put_env(:elixir, :ansi_enabled, false)
      assert Pincer.CLI.prompt_label() == "[User]: "
    end
  end

  describe "format_status/1 and fetch_status/2" do
    test "formats idle session state with default model" do
      state = %{
        session_id: "cli_user",
        root_agent_id: "cli_user",
        status: :idle,
        model_override: nil
      }

      formatted = Pincer.CLI.format_status({:ok, state})
      assert formatted =~ "Idle"
      assert formatted =~ "Session: cli_user"
      assert formatted =~ "Agent: cli_user"
      assert formatted =~ "Model: default"
    end

    test "formats working session state with active model override" do
      state = %{
        session_id: "cli_user",
        root_agent_id: "architect",
        status: :working,
        model_override: %{provider: "openrouter", model: "anthropic/claude-3.5-sonnet"}
      }

      formatted = Pincer.CLI.format_status(state)
      assert formatted =~ "Working"
      assert formatted =~ "Session: cli_user"
      assert formatted =~ "Agent: architect"
      assert formatted =~ "Model: openrouter:anthropic/claude-3.5-sonnet"
    end

    test "formats error and badrpc responses gracefully without crashing" do
      assert Pincer.CLI.format_status({:error, :not_found}) =~ "offline"
      assert Pincer.CLI.format_status({:error, {:exit, {:noproc, :details}}}) =~ "offline"
      assert Pincer.CLI.format_status({:badrpc, :nodedown}) =~ "nodedown"
      assert Pincer.CLI.format_status({:error, {:badrpc, :nodedown}}) =~ "nodedown"
    end

    test "fetch_status/2 queries a session pid and handles offline targets gracefully" do
      session_pid =
        spawn(fn ->
          receive do
            {:"$gen_call", from, :get_status} ->
              GenServer.reply(
                from,
                {:ok,
                 %{
                   session_id: "cli_user",
                   root_agent_id: "cli_user",
                   status: :working,
                   model_override: %{provider: "groq", model: "llama-3.3-70b"}
                 }}
              )
          end
        end)

      assert {:ok, %{status: :working, root_agent_id: "cli_user"}} =
               Pincer.CLI.fetch_status(session_pid, "cli_user")

      assert {:error, {:exit, _reason}} = Pincer.CLI.fetch_status(session_pid, "cli_user")

      missing_id = "missing_cli_session_#{System.unique_integer([:positive])}"
      assert {:error, {:exit, _reason}} = Pincer.CLI.fetch_status(Node.self(), missing_id)

      assert {:error, {:badrpc, :nodedown}} =
               Pincer.CLI.fetch_status(:"offline_pincer_node@127.0.0.1", "cli_user")
    end
  end

  describe "docs/SPECS/CLI_INTERACTIVE.md alignment" do
    test "documents current CLI protocol and commands with no stale references" do
      spec = File.read!(Path.expand("../../docs/SPECS/CLI_INTERACTIVE.md", __DIR__))

      assert spec =~ "{:cli_output,"
      assert spec =~ "/status"
      assert spec =~ "/history"
      assert spec =~ "process_command/1"
      assert spec =~ "main/1"
      assert spec =~ "loop/1"
      assert spec =~ "send_message/2"
      assert spec =~ "format_status/1"

      refute spec =~ "{:assistant_reply_finished"
      refute spec =~ "{:sme_status"
      refute spec =~ "{:executor_finished"
      refute spec =~ "handle_input"
    end
  end
end
