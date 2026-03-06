# scripts/smoke_test_providers.exs
IO.puts("🚀 Starting LLM Provider Smoke Tests (Free Models)...")

Application.ensure_all_started(:pincer)

providers = [
  {"openrouter", "openrouter/free"},
  {"opencode_zen", "kimi-latest"},
  {"z_ai_coding", "glm-4.7"}
]

Enum.each(providers, fn {id, model} ->
  IO.puts("\n--- Testing Provider: #{id} (#{model}) ---")
  try do
    case Pincer.Ports.LLM.chat_completion([%{"role" => "user", "content" => "Responda apenas 'PONG'"}], provider: id, model: model) do
      {:ok, %{"content" => content}, usage} ->
        IO.puts("✅ Success!")
        IO.puts("   Response: #{String.trim(content)}")
        IO.puts("   Usage: #{inspect(usage)}")
      {:error, reason} ->
        IO.puts("❌ Failed: #{inspect(reason)}")
    end
  rescue
    e -> IO.puts("💥 Crashed: #{inspect(e)}")
  end
end)

IO.puts("\n🏁 Smoke Tests Finished.")
