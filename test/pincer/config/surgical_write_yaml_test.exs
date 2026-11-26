defmodule Pincer.Infra.ConfigSurgicalWriteYamlTest do
  use ExUnit.Case, async: false

  alias Pincer.Infra.Config

  @config_path Path.expand("config.yaml", File.cwd!())

  @runtime_keys [
    :channels,
    :default_llm_provider,
    :gateway,
    :health_port,
    :introspection,
    :llm,
    :memory,
    :sandbox,
    :sandbox_adapter,
    :sqlite_path,
    :sqlite_vec,
    :storage_adapter,
    :tools
  ]

  @full_sample_yaml """
  # Top-level config comment
  channels:
    cli:
      adapter: "Pincer.Channels.CLI"
      enabled: true
    telegram:
      adapter: "Pincer.Channels.Telegram"
      enabled: false
      token_env: "TELEGRAM_BOT_TOKEN"
    discord:
      adapter: "Pincer.Channels.Discord"
      enabled: false
  memory:
    enabled: true
    window_size: 20
  llm:
    groq:
      base_url: "https://api.groq.com/openai/v1/chat/completions"
      default_model: "openai/gpt-oss-120b"
    openrouter:
      base_url: "https://openrouter.ai/api/v1/chat/completions"
      default_model: "google/gemini-2.0-flash-exp:free"
    provider: "groq"
  introspection:
    provider: "groq"
    model: "openai/gpt-oss-20b"
  gateway:
    bind: "127.0.0.1"
  # Keep health listener on 4002
  health_port: 4002
  sandbox:
    adapter: "local"
    local:
      # bubblewrap transport
      transport: "bwrap"
      bwrap:
        network: "none"
  tools:
    restrict_to_workspace: true
  # trailing footer comment
  """

  defp restore_config_env do
    original = File.read!(@config_path)
    previous = Enum.map(@runtime_keys, &{&1, Application.fetch_env(:pincer, &1)})

    on_exit(fn ->
      File.write!(@config_path, original)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:pincer, key, value)
        {key, :error} -> Application.delete_env(:pincer, key)
      end)
    end)
  end

  describe "put_scalar/3 block boundary preservation" do
    test "does not leak into sibling top-level section when parent lacks sub-key" do
      yaml = """
      llm:
        groq:
          base_url: "https://api.groq.com"
      memory:
        provider: "local"
      """

      updated = Config.put_scalar(yaml, ["llm", "provider"], "openrouter")

      assert {:ok, parsed} = YamlElixir.read_from_string(updated)
      assert parsed["llm"]["provider"] == "openrouter"
      assert parsed["llm"]["groq"]["base_url"] == "https://api.groq.com"
      assert parsed["memory"]["provider"] == "local"
    end

    test "does not leak into sibling nested block when matched sub-block lacks leaf key" do
      yaml = """
      llm:
        groq:
          base_url: "https://api.groq.com"
        openrouter:
          default_model: "old-openrouter-model"
      tools:
        restrict_to_workspace: true
      """

      updated = Config.put_scalar(yaml, ["llm", "groq", "default_model"], "llama-3.3-70b")

      assert {:ok, parsed} = YamlElixir.read_from_string(updated)
      assert parsed["llm"]["groq"]["base_url"] == "https://api.groq.com"
      assert parsed["llm"]["groq"]["default_model"] == "llama-3.3-70b"
      assert parsed["llm"]["openrouter"]["default_model"] == "old-openrouter-model"
      assert parsed["tools"] == %{"restrict_to_workspace" => true}
    end

    test "does not match grandchild key when targeting direct child key" do
      yaml = """
      channels:
        telegram:
          enabled: false
      """

      updated = Config.put_scalar(yaml, ["channels", "enabled"], true)

      assert {:ok, parsed} = YamlElixir.read_from_string(updated)
      assert parsed["channels"]["enabled"] == true
      assert parsed["channels"]["telegram"]["enabled"] == false
    end

    test "updates only targeted section across memory, tools, channels, sandbox, and llm" do
      updated =
        @full_sample_yaml
        |> Config.put_scalar(["channels", "telegram", "enabled"], true)
        |> Config.put_scalar(["memory", "window_size"], 50)
        |> Config.put_scalar(["tools", "restrict_to_workspace"], false)
        |> Config.put_scalar(["sandbox", "local", "bwrap", "network"], "host")
        |> Config.put_scalar(
          ["llm", "openrouter", "default_model"],
          "anthropic/claude-3.7-sonnet"
        )

      assert {:ok, parsed} = YamlElixir.read_from_string(updated)
      assert parsed["channels"]["cli"]["enabled"] == true
      assert parsed["channels"]["telegram"]["enabled"] == true
      assert parsed["channels"]["discord"]["enabled"] == false
      assert parsed["memory"] == %{"enabled" => true, "window_size" => 50}
      assert parsed["tools"] == %{"restrict_to_workspace" => false}
      assert parsed["sandbox"]["local"]["bwrap"]["network"] == "host"
      assert parsed["sandbox"]["local"]["transport"] == "bwrap"
      assert parsed["llm"]["openrouter"]["default_model"] == "anthropic/claude-3.7-sonnet"
      assert parsed["llm"]["groq"]["default_model"] == "openai/gpt-oss-120b"
      assert parsed["introspection"]["provider"] == "groq"

      assert updated =~ "# Top-level config comment"
      assert updated =~ "# Keep health listener on 4002"
      assert updated =~ "# bubblewrap transport"
      assert updated =~ "# trailing footer comment"
    end
  end

  describe "put_scalar/3 append_path and descend_for_append edge cases" do
    test "appends cleanly when input has no trailing newline" do
      yaml = "llm:\n  provider: \"groq\""
      updated = Config.put_scalar(yaml, ["memory", "enabled"], true)

      assert {:ok, parsed} = YamlElixir.read_from_string(updated)
      assert parsed["llm"] == %{"provider" => "groq"}
      assert parsed["memory"] == %{"enabled" => true}
    end

    test "appends at end of parent block even when last child is a nested block without blank lines" do
      yaml = """
      llm:
        groq:
          default_model: "m1"
      tools:
        restrict_to_workspace: true
      """

      updated = Config.put_scalar(yaml, ["llm", "provider"], "groq")

      assert {:ok, parsed} = YamlElixir.read_from_string(updated)
      assert parsed["llm"] == %{"groq" => %{"default_model" => "m1"}, "provider" => "groq"}
      assert parsed["tools"] == %{"restrict_to_workspace" => true}
    end

    test "appends into an empty parent block using child indentation instead of sibling indent" do
      yaml = """
      memory:
      tools:
        restrict_to_workspace: true
      """

      updated = Config.put_scalar(yaml, ["memory", "enabled"], true)

      assert {:ok, parsed} = YamlElixir.read_from_string(updated)
      assert parsed["memory"] == %{"enabled" => true}
      assert parsed["tools"] == %{"restrict_to_workspace" => true}
    end

    test "appends into a comment-only parent block while preserving comments and trailing blank lines" do
      yaml = """
      memory:
        # memory settings

      tools:
        restrict_to_workspace: true
      """

      updated = Config.put_scalar(yaml, ["memory", "enabled"], true)

      assert {:ok, parsed} = YamlElixir.read_from_string(updated)
      assert parsed["memory"] == %{"enabled" => true}
      assert parsed["tools"] == %{"restrict_to_workspace" => true}
      assert updated =~ "  # memory settings\n  enabled: true\n\ntools:"
    end

    test "appends inside parent block before unindented comment belonging to next section" do
      updated = Config.put_scalar(@full_sample_yaml, ["gateway", "port"], 4000)

      assert {:ok, parsed} = YamlElixir.read_from_string(updated)
      assert parsed["gateway"] == %{"bind" => "127.0.0.1", "port" => 4000}
      assert parsed["health_port"] == 4002
      assert updated =~ "  bind: \"127.0.0.1\"\n  port: 4000\n# Keep health listener on 4002"
    end

    test "expands an empty inline map {} cleanly when appending nested keys" do
      yaml = """
      memory: {}
      tools:
        restrict_to_workspace: true
      """

      updated = Config.put_scalar(yaml, ["memory", "enabled"], true)

      assert {:ok, parsed} = YamlElixir.read_from_string(updated)
      assert parsed["memory"] == %{"enabled" => true}
      assert parsed["tools"] == %{"restrict_to_workspace" => true}
    end

    test "creates missing intermediate blocks across sandbox, memory, tools, and channels" do
      yaml = """
      channels:
        cli:
          enabled: true
      """

      updated =
        yaml
        |> Config.put_scalar(["memory", "vector", "dimensions"], 1024)
        |> Config.put_scalar(["sandbox", "local", "bwrap", "network"], "none")
        |> Config.put_scalar(["tools", "shell", "timeout_ms"], 5000)

      assert {:ok, parsed} = YamlElixir.read_from_string(updated)
      assert parsed["channels"]["cli"]["enabled"] == true
      assert parsed["memory"]["vector"]["dimensions"] == 1024
      assert parsed["sandbox"]["local"]["bwrap"]["network"] == "none"
      assert parsed["tools"]["shell"]["timeout_ms"] == 5000
    end

    test "handles empty and comment-only YAML documents cleanly" do
      assert {:ok, %{"memory" => %{"enabled" => true}}} =
               ""
               |> Config.put_scalar(["memory", "enabled"], true)
               |> YamlElixir.read_from_string()

      comment_only = "# Pincer configuration\n"
      updated = Config.put_scalar(comment_only, ["tools", "restrict_to_workspace"], true)

      assert {:ok, %{"tools" => %{"restrict_to_workspace" => true}}} =
               YamlElixir.read_from_string(updated)

      assert updated =~ "# Pincer configuration"
    end

    test "escapes control characters and quotes in scalar strings" do
      updated = Config.put_scalar("a:\n  b: 1\n", ["a", "b"], "line1\nline2\t\"quoted\"\\end")

      assert {:ok, parsed} = YamlElixir.read_from_string(updated)
      assert parsed["a"]["b"] == "line1\nline2\t\"quoted\"\\end"
    end
  end

  describe "set_model/2 preservation and error resilience" do
    setup do
      restore_config_env()
      :ok
    end

    test "preserves memory, tools, channels, sandbox, and comments on full config.yaml update" do
      File.write!(@config_path, @full_sample_yaml)

      assert {:ok, "deepseek-r1", "openrouter"} = Config.set_model("deepseek-r1", "openrouter")

      raw = File.read!(@config_path)
      assert raw =~ "# Top-level config comment"
      assert raw =~ "# Keep health listener on 4002"
      assert raw =~ "# bubblewrap transport"
      assert raw =~ "# trailing footer comment"

      assert {:ok, parsed} = YamlElixir.read_from_string(raw)
      assert parsed["llm"]["provider"] == "openrouter"
      assert parsed["llm"]["openrouter"]["default_model"] == "deepseek-r1"
      assert parsed["llm"]["groq"]["default_model"] == "openai/gpt-oss-120b"
      assert parsed["memory"] == %{"enabled" => true, "window_size" => 20}
      assert parsed["tools"] == %{"restrict_to_workspace" => true}
      assert parsed["channels"]["telegram"]["token_env"] == "TELEGRAM_BOT_TOKEN"
      assert parsed["sandbox"]["local"]["bwrap"]["network"] == "none"
    end

    test "does not raise when llm section is missing or empty in config.yaml" do
      without_llm = """
      channels:
        cli:
          enabled: true
      memory:
        enabled: true
      sandbox:
        adapter: "local"
      tools:
        restrict_to_workspace: true
      """

      File.write!(@config_path, without_llm)
      assert {:ok, "gpt-4o", "openrouter"} = Config.set_model("gpt-4o")

      assert {:ok, parsed} = YamlElixir.read_from_file(@config_path)
      assert parsed["llm"]["provider"] == "openrouter"
      assert parsed["llm"]["openrouter"]["default_model"] == "gpt-4o"
      assert parsed["memory"] == %{"enabled" => true}
      assert parsed["tools"] == %{"restrict_to_workspace" => true}
      assert parsed["channels"] == %{"cli" => %{"enabled" => true}}
      assert parsed["sandbox"] == %{"adapter" => "local"}

      empty_llm = """
      llm:
      tools:
        restrict_to_workspace: true
      """

      File.write!(@config_path, empty_llm)
      assert {:ok, "gpt-4o-mini", "openrouter"} = Config.set_model("gpt-4o-mini")

      assert {:ok, parsed_empty} = YamlElixir.read_from_file(@config_path)
      assert parsed_empty["llm"]["provider"] == "openrouter"
      assert parsed_empty["llm"]["openrouter"]["default_model"] == "gpt-4o-mini"
      assert parsed_empty["tools"] == %{"restrict_to_workspace" => true}
    end
  end
end
