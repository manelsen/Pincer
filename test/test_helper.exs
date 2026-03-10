System.put_env("PINCER_DB_HOST", System.get_env("PINCER_DB_HOST", "localhost"))
System.put_env("PINCER_DB_PORT", System.get_env("PINCER_DB_PORT", "5432"))
System.put_env("PINCER_DB_USER", System.get_env("PINCER_DB_USER", "postgres"))
System.put_env("PINCER_DB_PASSWORD", System.get_env("PINCER_DB_PASSWORD", "postgres"))
System.put_env("PINCER_DB_NAME", System.get_env("PINCER_DB_NAME", "pincer_test"))

for task <- ["ecto.drop", "ecto.create", "ecto.migrate"] do
  Mix.Task.reenable(task)
end

try do
  Mix.Task.run("ecto.drop", ["--quiet"])
rescue
  _ -> :ok
end

Mix.Task.run("ecto.create", ["--quiet"])
Mix.Task.run("ecto.migrate", ["--quiet"])

ExUnit.start()

# Mock credentials
System.put_env("MOCK_KEY", "test-token")

# Configuração de provedor para testes com Mox
Application.put_env(:pincer, :llm_providers, %{
  "test" => %{
    adapter: Pincer.LLM.ClientMock,
    base_url: "http://mock",
    default_model: "test-model",
    env_key: "MOCK_KEY"
  }
})

Application.put_env(:pincer, :default_llm_provider, "test")

# Clean up any leftover workspaces from previous test runs
File.rm_rf!("tmp/test_workspaces")
