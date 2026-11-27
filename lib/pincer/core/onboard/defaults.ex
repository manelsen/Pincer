defmodule Pincer.Core.Onboard.Defaults do
  @moduledoc false

  @default_sqlite_path "data/pincer.db"

  @spec defaults() :: map()
  def defaults, do: defaults([])

  @spec defaults(keyword()) :: map()
  def defaults(opts) when is_list(opts) do
    sqlite_path =
      opts
      |> Keyword.get(:sqlite_path)
      |> normalize_sqlite_path()

    %{
      "channels" => default_channels(),
      "llm" => default_llm(),
      "mcp" => default_mcp(),
      "storage" => %{"adapter" => "sqlite", "path" => sqlite_path, "vec" => "auto"},
      "sandbox" => %{"adapter" => "local"}
    }
  end

  @doc "Returns `true` when the onboarding config targets embedded SQLite."
  @spec sqlite_storage_config?(map()) :: boolean()
  def sqlite_storage_config?(config) when is_map(config) do
    case get_in(config, ["storage", "adapter"]) do
      nil -> true
      adapter -> normalize_adapter(adapter) == "sqlite"
    end
  end

  def sqlite_storage_config?(_), do: false

  defp normalize_adapter(adapter) when is_atom(adapter) do
    adapter |> Atom.to_string() |> normalize_adapter()
  end

  defp normalize_adapter(adapter) when is_binary(adapter) do
    case adapter |> String.trim() |> String.downcase() do
      "sqlite3" -> "sqlite"
      other -> other
    end
  end

  defp normalize_adapter(_), do: nil

  @doc "Extracts the configured SQLite database path with fallback to `#{@default_sqlite_path}`."
  @spec sqlite_path(map()) :: String.t()
  def sqlite_path(config) when is_map(config) do
    config
    |> get_in(["storage", "path"])
    |> normalize_sqlite_path()
  end

  def sqlite_path(_), do: @default_sqlite_path

  defp normalize_sqlite_path(value) when is_binary(value) do
    case String.trim(value) do
      "" -> @default_sqlite_path
      trimmed -> trimmed
    end
  end

  defp normalize_sqlite_path(_), do: @default_sqlite_path

  defp default_channels do
    %{
      "telegram" => %{
        "enabled" => true,
        "adapter" => "Pincer.Channels.Telegram",
        "token_env" => "TELEGRAM_BOT_TOKEN"
      },
      "cli" => %{
        "enabled" => true,
        "adapter" => "Pincer.Channels.CLI"
      },
      "discord" => %{
        "enabled" => true,
        "adapter" => "Pincer.Channels.Discord",
        "token_env" => "DISCORD_BOT_TOKEN"
      },
      "whatsapp" => %{
        "enabled" => false,
        "adapter" => "Pincer.Channels.WhatsApp",
        "dm_policy" => %{"mode" => "pairing"},
        "bridge" => %{
          "auth_dir" => "sessions/whatsapp",
          "qr_ascii" => true,
          "qr_ascii_small" => true,
          "pairing_phone" => ""
        }
      }
    }
  end

  defp default_llm do
    %{
      "provider" => "z_ai",
      "z_ai" => %{
        "base_url" => "https://api.z.ai/api/coding/paas/v4/chat/completions",
        "default_model" => "glm-5.3"
      },
      "opencode_zen" => %{
        "base_url" => "https://opencode.ai/zen/v1/chat/completions",
        "default_model" => "kimi-k2.5-free"
      },
      "openrouter" => %{
        "base_url" => "https://openrouter.ai/api/v1/chat/completions",
        "default_model" => "openrouter/free"
      }
    }
  end

  defp default_mcp do
    %{
      "servers" => %{
        "filesystem" => %{
          "command" => "npx",
          "args" => ["-y", "@modelcontextprotocol/server-filesystem", "."]
        },
        "github" => %{
          "command" => "npx",
          "args" => ["-y", "@modelcontextprotocol/server-github"]
        }
      }
    }
  end

  @spec required_paths() :: [String.t()]
  def required_paths do
    [
      "config.yaml",
      Pincer.Core.AgentPaths.base_dir(),
      "sessions",
      "memory",
      "#{Pincer.Core.AgentPaths.base_dir()}/.template/.pincer/BOOTSTRAP.md",
      "#{Pincer.Core.AgentPaths.base_dir()}/.template/.pincer/IDENTITY.md",
      "#{Pincer.Core.AgentPaths.base_dir()}/.template/.pincer/SOUL.md",
      "#{Pincer.Core.AgentPaths.base_dir()}/.template/.pincer/USER.md",
      "#{Pincer.Core.AgentPaths.base_dir()}/.template/.pincer/MEMORY.md",
      "#{Pincer.Core.AgentPaths.base_dir()}/.template/.pincer/HISTORY.md"
    ]
  end

  @spec available_capabilities() :: [String.t()]
  def available_capabilities do
    ["workspace_dirs", "memory_file", "config_yaml"]
  end

  @spec normalize_capabilities(nil | list()) :: [String.t()]
  def normalize_capabilities(nil), do: available_capabilities()

  def normalize_capabilities(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @spec normalize_remote_capabilities(term()) :: [String.t()]
  def normalize_remote_capabilities(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize_remote_capabilities(_), do: []

  @provider_env_keys %{
    "openrouter" => "OPENROUTER_API_KEY",
    "z_ai" => "Z_AI_API_KEY",
    "z_ai_coding" => "Z_AI_CODING_API_KEY",
    "opencode_zen" => "OPENCODE_ZEN_API_KEY",
    "google" => "GOOGLE_API_KEY",
    "moonshot" => "MOONSHOT_API_KEY",
    "moonshot_coding" => "MOONSHOT_CODING_API_KEY",
    "groq" => "GROQ_API_KEY",
    "groq_whisper" => "GROQ_API_KEY",
    "minimax" => "MINIMAX_API_KEY",
    "anthropic" => "ANTHROPIC_API_KEY",
    "openai" => "OPENAI_API_KEY",
    "deepseek" => "DEEPSEEK_API_KEY",
    "qwen" => "DASHSCOPE_API_KEY",
    "mistral" => "MISTRAL_API_KEY"
  }

  @recommended_models %{
    "openrouter" => "openrouter/free",
    "groq" => "openai/gpt-oss-120b",
    "groq_whisper" => "whisper-large-v3-turbo",
    "anthropic" => "claude-sonnet-5-5",
    "google" => "gemini-3.8-flash",
    "openai" => "gpt-6.2-sol",
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

  @doc """
  Returns the environment variable name for the given provider ID, or nil if unknown or keyless.
  """
  @spec provider_env_key(String.t() | nil) :: String.t() | nil
  def provider_env_key(provider) when is_binary(provider),
    do: Map.get(@provider_env_keys, provider)

  def provider_env_key(_), do: nil

  @doc """
  Returns the recommended default model ID for the given provider ID.
  """
  @spec recommended_model(String.t() | nil) :: String.t()
  def recommended_model(provider) when is_binary(provider),
    do: Map.get(@recommended_models, provider, "openrouter/free")

  def recommended_model(_), do: "openrouter/free"

  @spec capability_operations(String.t(), map(), keyword()) :: [Pincer.Core.Onboard.operation()]
  def capability_operations(capability, config, opts \\ [])

  def capability_operations("workspace_dirs", _config, opts) do
    base = workspaces_dir(opts)

    [
      {:mkdir_p, base},
      {:mkdir_p, "sessions"},
      {:mkdir_p, "memory"}
    ]
  end

  def capability_operations("memory_file", _config, opts) do
    tpl = Path.join(workspaces_dir(opts), ".template")

    [
      {:mkdir_p, Path.join(tpl, ".pincer")},
      {:write_if_missing, Path.join([tpl, ".pincer", "BOOTSTRAP.md"]),
       Pincer.Core.AgentPaths.default_bootstrap()},
      {:write_if_missing, Path.join([tpl, ".pincer", "IDENTITY.md"]),
       Pincer.Core.AgentPaths.default_identity()},
      {:write_if_missing, Path.join([tpl, ".pincer", "SOUL.md"]),
       Pincer.Core.AgentPaths.default_soul()},
      {:write_if_missing, Path.join([tpl, ".pincer", "USER.md"]),
       Pincer.Core.AgentPaths.default_user()},
      {:write_if_missing, Path.join([tpl, ".pincer", "MEMORY.md"]),
       Pincer.Core.AgentPaths.default_memory()},
      {:write_if_missing, Path.join([tpl, ".pincer", "HISTORY.md"]),
       Pincer.Core.AgentPaths.default_history()}
    ]
  end

  def capability_operations("config_yaml", config, opts) do
    config_file = Keyword.get(opts, :config_file, "config.yaml")
    [{:write_config_yaml, config_file, config}]
  end

  def capability_operations(_unknown, _config, _opts), do: []

  # The plan carries paths relative to the onboarding root, so this default is
  # relative too; callers pin an absolute default when they know the root.
  defp workspaces_dir(opts) do
    case Keyword.get(opts, :workspaces_dir) do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> Pincer.Core.AgentPaths.base_dir()
    end
  end
end
