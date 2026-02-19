# reload_config.exs
node_name = :"pincer_server@localhost"
cookie = :pincer_secret

{:ok, _} = Node.start(:"reloader_#{System.unique_integer([:positive])}@localhost", :shortnames)
Node.set_cookie(Node.self(), cookie)

if Node.connect(node_name) do
  IO.puts "Conectado. Recarregando Config..."
  result = :rpc.call(node_name, Pincer.Config, :load, [])
  IO.inspect(result)
  
  IO.puts "Reiniciando Supervisor de Canais..."
  # Reinicia o Supervisor para pegar a nova config
  case :rpc.call(node_name, Process, :whereis, [Pincer.Channels.Supervisor]) do
    pid when is_pid(pid) ->
      Process.exit(pid, :kill)
      IO.puts "Supervisor morto. O Pincer.Supervisor deve reiniciá-lo."
    _ ->
      IO.puts "Supervisor não encontrado."
  end
else
  IO.puts "Falha ao conectar."
end
