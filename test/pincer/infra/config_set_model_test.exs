defmodule Pincer.Infra.ConfigSetModelTest do
  use ExUnit.Case, async: false

  alias Pincer.Infra.Config

  @config_path Path.expand("config.yaml", File.cwd!())

  @runtime_keys [:channels, :default_llm_provider, :llm]

  @sample_config """
  channels:
    cli:
      adapter: "Pincer.Channels.CLI"
      enabled: true
  llm:
    groq:
      base_url: "https://api.groq.com/openai/v1/chat/completions"
      default_model: "llama-3.3-70b-versatile"
    provider: "groq"
  tools:
    restrict_to_workspace: true
  """

  setup do
    original = File.read!(@config_path)
    File.write!(@config_path, @sample_config)

    # `set_model/2` reloads the YAML into the application env, so the file alone
    # is not enough to restore the previous state: the provider keys this suite
    # rewrites must be put back too, or later tests resolve a real provider
    # instead of the test double.
    previous = Enum.map(@runtime_keys, &{&1, Application.fetch_env(:pincer, &1)})

    on_exit(fn ->
      File.write!(@config_path, original)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:pincer, key, value)
        {key, :error} -> Application.delete_env(:pincer, key)
      end)
    end)

    :ok
  end

  describe "set_model/2 config.yaml round-trip" do
    test "updates the provider default_model and provider" do
      assert {:ok, "new-model", "groq"} = Config.set_model("new-model")

      {:ok, parsed} = YamlElixir.read_from_file(@config_path)
      assert parsed["llm"]["provider"] == "groq"
      assert parsed["llm"]["groq"]["default_model"] == "new-model"
    end

    test "preserves sections that were not edited" do
      assert {:ok, _, _} = Config.set_model("another-model", "groq")

      {:ok, parsed} = YamlElixir.read_from_file(@config_path)
      assert parsed["channels"]["cli"]["enabled"] == true
      assert parsed["tools"] == %{"restrict_to_workspace" => true}
      assert parsed["llm"]["groq"]["base_url"] =~ "api.groq.com"
    end

    test "adds a provider block when the provider is not configured yet" do
      assert {:ok, "brand-model", "brand"} = Config.set_model("brand-model", "brand")

      {:ok, parsed} = YamlElixir.read_from_file(@config_path)
      assert parsed["llm"]["provider"] == "brand"
      assert parsed["llm"]["brand"]["default_model"] == "brand-model"
      assert parsed["llm"]["groq"]["default_model"] == "llama-3.3-70b-versatile"
    end

    test "keeps the file valid YAML after repeated updates" do
      assert {:ok, _, _} = Config.set_model("m1", "groq")
      assert {:ok, _, _} = Config.set_model("m2", "openrouter")
      assert {:ok, _, _} = Config.set_model("m3", "openrouter")

      assert {:ok, parsed} = YamlElixir.read_from_file(@config_path)
      assert parsed["llm"]["openrouter"]["default_model"] == "m3"
      assert parsed["channels"]["cli"]["adapter"] == "Pincer.Channels.CLI"
    end
  end

  describe "put_scalar/3" do
    test "quotes values that would otherwise break YAML" do
      updated = Config.put_scalar("a:\n  b: 1\n", ["a", "b"], ~s(x"y: z))

      assert {:ok, parsed} = YamlElixir.read_from_string(updated)
      assert parsed["a"]["b"] == ~s(x"y: z)
    end

    test "is idempotent for the same value" do
      once = Config.put_scalar(@sample_config, ["llm", "provider"], "groq")
      twice = Config.put_scalar(once, ["llm", "provider"], "groq")
      assert once == twice
    end
  end
end
