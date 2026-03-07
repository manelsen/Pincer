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
