defmodule Pincer.Core.Onboard.Defaults do
  @moduledoc false

  alias Pincer.Infra.SQLite

  @default_sqlite_path "data/pincer.db"

  @spec defaults() :: map()
  def defaults, do: defaults([])

  @spec defaults(keyword()) :: map()
  def defaults(opts) when is_list(opts) do
    storage =
      case SQLite.parse_storage_backend(Keyword.get(opts, :storage, :postgres)) do
        {:ok, mode} -> mode
        _ -> :postgres
      end

    base = %{
      "channels" => default_channels(),
      "llm" => default_llm(),
      "mcp" => default_mcp()
    }

    case storage do
      :sqlite ->
        sqlite_path =
          opts
          |> Keyword.get(:sqlite_path)
          |> normalize_sqlite_path()

        base
        |> Map.put("storage", %{"adapter" => "sqlite", "path" => sqlite_path})
        |> Map.put("sandbox", %{"adapter" => "local"})

      :postgres ->
        Map.put(base, "database", default_database())
    end
  end

  @doc "Returns `true` when the onboarding config targets embedded SQLite."
  @spec sqlite_storage_config?(map()) :: boolean()
  def sqlite_storage_config?(config) when is_map(config) do
    SQLite.detect_storage_backend(config) == :sqlite
  end

  def sqlite_storage_config?(_), do: false

  @doc "Extracts the configured SQLite database path with fallback to `#{@default_sqlite_path}`."
  @spec sqlite_path(map()) :: String.t()
  def sqlite_path(config) when is_map(config) do
    candidate =
      get_in(config, ["storage", "path"]) ||
        get_in(config, ["database", "path"])

    normalize_sqlite_path(candidate)
  end

  def sqlite_path(_), do: @default_sqlite_path

  defp normalize_sqlite_path(value) when is_binary(value) do
    case String.trim(value) do
      "" -> @default_sqlite_path
      trimmed -> trimmed
    end
  end

  defp normalize_sqlite_path(_), do: @default_sqlite_path

  defp default_database do
    %{
      "adapter" => "Ecto.Adapters.PostgreSQL",
      "hostname" => "localhost",
      "port" => 5432,
      "username" => "postgres",
      "password" => "postgres",
      "database" => "pincer",
      "pool_size" => 10
    }
  end

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
        "default_model" => "glm-4.7"
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
    "anthropic" => "ANTHROPIC_API_KEY"
  }

  @doc """
  Returns the environment variable name for the given provider ID, or nil if unknown.
  """
  @spec provider_env_key(String.t() | nil) :: String.t() | nil
  def provider_env_key(provider) when is_binary(provider),
    do: Map.get(@provider_env_keys, provider)

  def provider_env_key(_), do: nil

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
