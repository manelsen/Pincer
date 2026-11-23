# :chaos and :stress are load/performance suites: they assert on latency and
# must not compete with the rest of the suite. Run them explicitly with
# `mix test --only chaos` / `--only stress`.
ExUnit.start(exclude: [:docker, :bwrap, :chaos, :stress])

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
