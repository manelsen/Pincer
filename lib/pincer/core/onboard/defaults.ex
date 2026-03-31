defmodule Pincer.Core.Onboard.Defaults do
  @moduledoc false

  @spec defaults() :: map()
  def defaults do
    %{
      "database" => %{
        "adapter" => "Ecto.Adapters.PostgreSQL",
        "hostname" => "localhost",
        "port" => 5432,
        "username" => "postgres",
        "password" => "postgres",
        "database" => "pincer",
        "pool_size" => 10
      },
      "channels" => %{
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
            "command" => "node",
            "args" => ["infrastructure/whatsapp/baileys_bridge.js"],
            "auth_dir" => "sessions/whatsapp",
            "qr_ascii" => true,
            "qr_ascii_small" => true,
            "pairing_phone" => ""
          }
        }
      },
      "llm" => %{
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
      },
      "mcp" => %{
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

  @spec capability_operations(String.t(), map()) :: [Pincer.Core.Onboard.operation()]
  def capability_operations("workspace_dirs", _config) do
    base = Pincer.Core.AgentPaths.base_dir()

    [
      {:mkdir_p, base},
      {:mkdir_p, "sessions"},
      {:mkdir_p, "memory"}
    ]
  end

  def capability_operations("memory_file", _config) do
    tpl = Pincer.Core.AgentPaths.template_workspace()

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

  def capability_operations("config_yaml", config) do
    [{:write_config_yaml, "config.yaml", config}]
  end

  def capability_operations(_unknown, _config), do: []
end
