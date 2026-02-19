defmodule Mix.Tasks.Pincer.Server do
  @moduledoc """
  Inicia o Servidor Pincer (Nó Persistente).
  Uso: mix pincer.server
  """
  use Mix.Task

  def run(_args) do
    # Configura o nó para ser distribuído
    start_node()

    IO.puts(IO.ANSI.green() <> "=== Pincer Server (Immortal Node) ===" <> IO.ANSI.reset())
    IO.puts("Nó: #{Node.self()}")
    IO.puts("Cookie: #{Node.get_cookie()}")
    
    # Inicia a aplicação completa
    Mix.Task.run("app.start", [])
    
    # Mantém o processo vivo
    Process.sleep(:infinity)
  end

  defp start_node do
    # Tenta iniciar como pincer_server@localhost (ou hostname)
    # Requer que o epmd esteja rodando (mix inicia automaticamente)
    unless Node.alive?() do
      {:ok, _} = Node.start(:"pincer_server@localhost", :shortnames)
      Node.set_cookie(Node.self(), :pincer_secret)
    end
  end
end
