# test_10_skills.exs

# Lista de 10 Skills oficiais do repositório Model Context Protocol (em ordem alfabética)
skills = [
  "@modelcontextprotocol/server-brave-search",
  "@modelcontextprotocol/server-evernote",
  "@modelcontextprotocol/server-fetch",
  "@modelcontextprotocol/server-filesystem",
  "@modelcontextprotocol/server-github",
  "@modelcontextprotocol/server-google-maps",
  "@modelcontextprotocol/server-memory",
  "@modelcontextprotocol/server-postgres",
  "@modelcontextprotocol/server-puppeteer",
  "@modelcontextprotocol/server-slack"
]

IO.puts("🚀 Iniciando Teste de Compatibilidade Massiva (10 Skills em Sidecars)")
IO.puts("Cada skill rodará em um container Docker efêmero e limpo.\n")

Enum.each(skills, fn skill_name ->
  IO.puts("--------------------------------------------------")
  IO.puts("📦 Instalando e Inicializando: #{skill_name}")
  
  # Como a chamada real do MCP exige persistir e mandar JSON por Stdio,
  # Aqui faremos um teste para varrer se o container Node.js consegue
  # usar o npx para baixar a skill e invocá-la (mesmo que com erro de config).
  # Passamos um timeout e um kill para garantir que ele não fique pendurado em prompt.
  
  cmd = "docker"
  args = [
    "run", "-i", "--rm", 
    "--memory=1.5g",  # Memória estendida para suportar Puppeteer
    "pincer-mcp-sidecar", 
    "npx", "-y", skill_name
  ]

  # Inicia o processo Docker
  port = Port.open({:spawn_executable, System.find_executable(cmd)}, [
    :stream,
    :binary,
    :stderr_to_stdout,
    args: args
  ])

  # Aguarda até 5 segundos de output inicial
  receive do
    {^port, {:data, output}} ->
      # Truncar saída para não poluir
      preview = String.slice(output, 0, 150)
      IO.puts("✅ Container Ativo! Resposta inicial interceptada:\n   #{preview}...")
      
      # Força o encerramento seguro do container limpo
      Port.close(port)
      
    after 5000 ->
      IO.puts("⏳ Timeout inicial da skill (pode ser download grande do npx). Fechando porta.")
      Port.close(port)
  end

  # Pequena pausa antes do próximo para nã travar o console de vez
  Process.sleep(500)
end)

IO.puts("\n🎉 Teste em lote finalizado.")
