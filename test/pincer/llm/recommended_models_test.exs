defmodule Pincer.LLM.RecommendedModelsTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Onboard.Defaults
  alias Pincer.LLM.Providers.Google

  @expected_defaults %{
    "google" => "gemini-3.8-flash",
    "openrouter" => "openrouter/free",
    "anthropic" => "claude-sonnet-5-5",
    "openai" => "gpt-6.2-sol",
    "groq" => "openai/gpt-oss-120b",
    "groq_whisper" => "whisper-large-v3-turbo",
    "z_ai" => "glm-5.3",
    "z_ai_coding" => "glm-5.4",
    "moonshot" => "kimi-k3",
    "moonshot_coding" => "k3.1-pro",
    "minimax" => "MiniMax-M3.1-Flash",
    "deepseek" => "deepseek-v4-flash",
    "qwen" => "qwen3.6-plus",
    "mistral" => "mistral-large-4",
    "ollama" => "qwen3.5:9b",
    "opencode_zen" => "kimi-k2.5-free"
  }

  test "config/config.exs registers all 16 providers with modern late-2026 defaults" do
    cfg = Config.Reader.read!("config/config.exs", env: :prod)
    providers = cfg |> Keyword.get(:pincer, []) |> Keyword.get(:llm_providers, %{})

    assert Map.keys(providers) |> Enum.sort() == Map.keys(@expected_defaults) |> Enum.sort()

    for {provider, expected_model} <- @expected_defaults do
      assert providers[provider][:default_model] == expected_model,
             "Expected #{provider} default_model to be #{expected_model}, got #{inspect(providers[provider][:default_model])}"
    end
  end

  test "Onboard.Defaults resolves env keys and modern recommended models for all providers" do
    expected_env_keys = %{
      "openai" => "OPENAI_API_KEY",
      "deepseek" => "DEEPSEEK_API_KEY",
      "qwen" => "DASHSCOPE_API_KEY",
      "mistral" => "MISTRAL_API_KEY",
      "anthropic" => "ANTHROPIC_API_KEY",
      "google" => "GOOGLE_API_KEY",
      "openrouter" => "OPENROUTER_API_KEY",
      "groq" => "GROQ_API_KEY",
      "z_ai" => "Z_AI_API_KEY",
      "moonshot" => "MOONSHOT_API_KEY",
      "minimax" => "MINIMAX_API_KEY",
      "opencode_zen" => "OPENCODE_ZEN_API_KEY",
      "ollama" => nil
    }

    for {provider, env_key} <- expected_env_keys do
      assert Defaults.provider_env_key(provider) == env_key
      model = Defaults.recommended_model(provider)
      assert model != "" and model != "default"
      refute model =~ ~r/mistral-7b|gemini-1\.5|claude-3|gpt-4o|moonshot-v1|MiniMax-M1/
    end
  end

  test "Google adapter falls back to modern Gemini models when API key is missing" do
    assert {:ok, [first | _] = models} = Google.list_models(%{})
    assert first == "gemini-3.8-flash"
    refute "gemini-1.5-flash" in models
  end

  test "profile templates and provider READMEs avoid retired model IDs and misspelled adapters" do
    legacy_pattern =
      ~r/claude-3|gemini-2\.0-flash|gemini-1\.5|gpt-4o(?!-mini-tts)|deepseek-chat|qwen-max|mistral-large-latest|moonshot-v1-8k|MiniMax-Text-01|llama3\.2|\bzen-1\b|OpenaiCompat/

    files =
      (Path.wildcard("priv/profiles/*.yaml") ++ Path.wildcard("packages/pincer_*/README.md"))
      |> Enum.sort()

    assert files != []

    for file <- files do
      content = File.read!(file)

      refute content =~ legacy_pattern,
             "Expected #{file} to use current model IDs and canonical adapter names"
    end
  end
end
