# debug_server.exs
node_name = :"pincer_server@localhost"
cookie = :pincer_secret

{:ok, _} = Node.start(:"debug_#{System.unique_integer([:positive])}@localhost", :shortnames)
Node.set_cookie(Node.self(), cookie)

if Node.connect(node_name) do
  IO.puts "Conectado ao #{node_name}"
  
  # Lista processos registrados
  registered = :rpc.call(node_name, Process, :registered, [])
  
  if Pincer.Channels.CLI in registered do
    IO.puts "✅ Pincer.Channels.CLI está rodando!"
  else
    IO.puts "❌ Pincer.Channels.CLI NÃO encontrado."
    IO.puts "Processos Pincer encontrados:"
    IO.inspect(Enum.filter(registered, fn name -> String.starts_with?(to_string(name), "Elixir.Pincer") end))
    
    IO.puts "\n--- DEBUG CONFIG ---"
    config = :rpc.call(node_name, Pincer.Config, :get, [:channels, :not_found])
    IO.puts "Configuração de Canais lida pelo servidor:"
    IO.inspect(config)
    
    specs = :rpc.call(node_name, Pincer.Channels.Factory, :create_channel_specs, [])
    IO.puts "Specs geradas pela Factory:"
    IO.inspect(specs)
  end
else
  IO.puts "Falha ao conectar."
end
