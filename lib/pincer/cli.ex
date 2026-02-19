defmodule Pincer.CLI do
  @moduledoc """
  Frontend do CLI.
  Pode rodar localmente (Standalone) ou conectar-se a um servidor remoto.
  """
  require Logger

  @session_id "cli_user"
  @backend_name Pincer.Channels.CLI

  def main(_args) do
    IO.puts(IO.ANSI.green() <> "=== Pincer CLI v0.2 (Distributed) ===" <> IO.ANSI.reset())
    IO.puts("Digite /q para sair.")

    target_node = connect_to_server()
    attach_to_backend(target_node)
    loop(target_node)
  end

  defp connect_to_server do
    unless Node.alive?() do
      {:ok, _} = Node.start(:"pincer_cli_#{System.unique_integer([:positive])}@localhost", :shortnames)
      Node.set_cookie(Node.self(), :pincer_secret)
    end

    server_node = :"pincer_server@localhost"

    if Node.connect(server_node) do
      IO.puts(IO.ANSI.blue() <> "🔗 Conectado ao Servidor Imortal: #{server_node}" <> IO.ANSI.reset())
      server_node
    else
      IO.puts(IO.ANSI.yellow() <> "⚠️ Servidor não encontrado. Iniciando modo Standalone..." <> IO.ANSI.reset())
      Mix.Task.run("app.start", [])
      ensure_local_session()
      Node.self()
    end
  end

  defp attach_to_backend(node) do
    try do
      GenServer.call({@backend_name, node}, :attach)
    catch
      :exit, _ -> 
        IO.puts(IO.ANSI.red() <> "❌ Falha ao conectar ao canal CLI no servidor." <> IO.ANSI.reset())
        System.halt(1)
    end
  end

  defp ensure_local_session do
    case Registry.lookup(Pincer.Session.Registry, @session_id) do
      [{_pid, _}] -> :ok
      [] -> Pincer.Session.Server.start_link(session_id: @session_id)
    end
  end

  def loop(target_node) do
    input = IO.gets(IO.ANSI.cyan() <> "[Manel]: " <> IO.ANSI.reset()) |> String.trim()
    
    case process_command(input) do
      :quit -> 
        IO.puts("Até mais!")
        System.halt(0)
      
      :clear ->
        IO.puts(IO.ANSI.clear() <> IO.ANSI.home())
        loop(target_node)
        
      {:send, msg} ->
        send_message(target_node, msg)
        await_response() 
        loop(target_node)
    end
  end

  def process_command("/quit"), do: :quit
  def process_command("/q"), do: :quit
  def process_command("/clear"), do: :clear
  def process_command(msg), do: {:send, msg}

  def send_message(node, msg) do
    # Envia para o Backend no nó alvo como INPUT do usuário
    GenServer.cast({@backend_name, node}, {:user_input, msg})
  end

  defp await_response do
    receive do
      {:cli_output, text} ->
        IO.puts("\n" <> IO.ANSI.green() <> "[Pincer]: " <> text <> IO.ANSI.reset() <> "\n")
        
        # Se for mensagem de status, continua esperando a resposta final
        if String.starts_with?(text, "📐") or String.starts_with?(text, "⚙️") do
          await_response()
        else
          # Se for resposta final (ou erro), sai do loop e volta pro prompt
          :ok
        end

      _ -> await_response()
    after
      60_000 -> IO.puts(IO.ANSI.red() <> "[Timeout] Sem resposta." <> IO.ANSI.reset())
    end
  end
end
