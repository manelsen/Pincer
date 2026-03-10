defmodule Pincer.Infra.Config do
  @moduledoc """
  Configuration loader and manager for the Pincer application.

  Config provides a unified interface for loading configuration from multiple
  sources with proper precedence: environment variables take priority over
  YAML configuration for sensitive values (API keys, tokens).

  ## Configuration Sources

  | Source | Priority | Purpose |
  |--------|----------|---------|
  | `.env` | Highest | API keys, tokens, secrets |
  | `config.yaml` | Lower | Database, LLM providers, MCP servers |
  | System env | Variable | Override any value |

  ## Configuration Structure

  The `config.yaml` file should contain:

      database:
        adapter: "Ecto.Adapters.PostgreSQL"
        hostname: "localhost"
        port: 5432
        username: "postgres"
        password: "postgres"
        database: "pincer"

      llm:
        provider: "opencode_zen"
        opencode_zen:
          base_url: "https://api.example.com"
          default_model: "model-id"
        openrouter:
          base_url: "https://openrouter.ai/api/v1"
          default_model: "anthropic/claude-3-opus"

      mcp:
        servers:
          filesystem:
            command: "mcp-filesystem"
            args: ["/path/to/root"]

  ## Environment Variables

  Required for token authentication:

      TELEGRAM_BOT_TOKEN=your-telegram-token
      OPENROUTER_API_KEY=your-openrouter-key
      OPENCODE_ZEN_API_KEY=your-opencode-key
      GITHUB_PERSONAL_ACCESS_TOKEN=your-github-token

  ## Usage

  Load configuration at application startup:

      # In application.ex
      def start(_type, _args) do
        Pincer.Infra.Config.load()
        # ... start supervisors
      end

  Access configuration throughout the application:

      # Get with default
      provider = Pincer.Infra.Config.get(:llm)["provider"]

      # Fetch required value (raises if missing)
      tokens = Pincer.Infra.Config.fetch!(:tokens)

  ## Hot Reloading Model

  Change the active LLM model at runtime:

      {:ok, model, provider} = Pincer.Infra.Config.set_model("gpt-4-turbo")

  ## Examples

      # Load all configuration
      :ok = Pincer.Infra.Config.load()

      # Get configuration value
      Pincer.Infra.Config.get(:llm)
      # => %{"provider" => "opencode_zen", "opencode_zen" => %{...}}

      # Get with default
      Pincer.Infra.Config.get(:unknown_key, "default_value")
      # => "default_value"

      # Fetch required value
      Pincer.Infra.Config.fetch!(:tokens)
      # => %{"telegram" => "bot123...", "openrouter" => "sk-or-..."}
  """

  @config_file "config.yaml"

  @doc """
  Loads configuration from `.env` and `config.yaml` into application environment.

  This function should be called once at application startup. It performs
  the following steps in order:

  1. Loads `.env` file and sets environment variables
  2. Reads `config.yaml` for structural configuration
  3. Collects API tokens from environment variables
  4. Configures LLM provider settings
  5. Sets up database adapter configuration

  ## Returns

    - `:ok` - Configuration loaded successfully
    - `:error` - Failed to load `config.yaml`

  ## Examples

      :ok = Pincer.Infra.Config.load()
      # => Prints status messages and loads config

  ## Side Effects

    - Sets `System.put_env/2` for `.env` values
    - Sets `Application.put_env/3` for all config sections
  """
  @spec load() :: :ok | :error
  def load do
    IO.puts("Loading environment variables from .env...")

    case File.read(".env") do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.each(fn line ->
          case String.split(line, "=", parts: 2) do
            [key, value] ->
              trimmed_key = String.trim(key)
              trimmed_value = String.trim(value) |> String.trim("\"") |> String.trim("'")
              System.put_env(trimmed_key, trimmed_value)

            _ ->
              :ok
          end
        end)

      {:error, _} ->
        IO.puts("Warning: .env file not found.")
    end

    case YamlElixir.read_from_file(@config_file) do
      {:ok, config} ->
        Enum.each(config, fn {key, value} ->
          Application.put_env(:pincer, String.to_atom(key), value)
        end)

        env_telegram = System.get_env("TELEGRAM_BOT_TOKEN")
        env_openrouter = System.get_env("OPENROUTER_API_KEY")
        env_opencode_zen = System.get_env("OPENCODE_ZEN_API_KEY")

        IO.puts(
          "Token ENV Telegram: #{if env_telegram && env_telegram != "", do: "OK", else: "NOT FOUND"}"
        )

        IO.puts(
          "Token ENV Opencode Zen: #{if env_opencode_zen && env_opencode_zen != "", do: "OK", else: "NOT FOUND"}"
        )

        tokens = %{
          "telegram" => env_telegram,
          "openrouter" => env_openrouter,
          "opencode_zen" => env_opencode_zen,
          "github" => System.get_env("GITHUB_PERSONAL_ACCESS_TOKEN")
        }

        final_tokens =
          tokens
          |> Enum.filter(fn {_, v} -> v != nil && v != "" end)
          |> Map.new()

        Application.put_env(:pincer, :tokens, final_tokens)

        if llm_config = config["llm"] do
          # Merge YAML config into existing Application env (from config.exs)
          current_llm = Application.get_env(:pincer, :llm, %{})
          merged_llm = Map.merge(current_llm, llm_config)
          Application.put_env(:pincer, :llm, merged_llm)

          provider = merged_llm["provider"] || merged_llm[:provider] || "openrouter"
          IO.puts("LLM Provider: #{provider}")
        end

        if db_config = config["database"] do
          current_repo_config = Application.get_env(:pincer, Pincer.Infra.Repo, [])

          ecto_config =
            db_config
            |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
            |> Keyword.merge(current_repo_config)

          ecto_config =
            case db_config["adapter"] do
              "Ecto.Adapters.PostgreSQL" ->
                ecto_config
                |> Keyword.put(:adapter, Ecto.Adapters.Postgres)
                |> Keyword.put(:types, Pincer.Infra.PostgrexTypes)
                |> maybe_put_runtime_override(:hostname, "PINCER_DB_HOST")
                |> maybe_put_runtime_override(:port, "PINCER_DB_PORT", &String.to_integer/1)
                |> maybe_put_runtime_override(:username, "PINCER_DB_USER")
                |> maybe_put_runtime_override(:password, "PINCER_DB_PASSWORD")
                |> maybe_put_runtime_override(:database, "PINCER_DB_NAME")
                |> maybe_put_runtime_override(
                  :pool_size,
                  "PINCER_DB_POOL_SIZE",
                  &String.to_integer/1
                )
                |> maybe_put_runtime_override(
                  :ssl,
                  "PINCER_DB_SSL",
                  &(&1 in ["1", "true", "TRUE"])
                )

              _ ->
                ecto_config
            end

          Application.put_env(:pincer, :repo, ecto_config)
        end

        :ok

      {:error, reason} ->
        IO.puts("Fatal error: Failed to load config.yaml: #{inspect(reason)}")
        :error
    end
  end

  @doc """
  Retrieves a configuration value from the application environment.

  ## Parameters

    - `key` - Atom key to look up in `:pincer` application env
    - `default` - Value to return if key is not set (default: `nil`)

  ## Returns

    - The configured value, or `default` if not found

  ## Examples

      iex> Pincer.Infra.Config.get(:llm)
      %{"provider" => "opencode_zen", ...}

      iex> Pincer.Infra.Config.get(:nonexistent, "fallback")
      "fallback"

      iex> Pincer.Infra.Config.get(:nonexistent)
      nil
  """
  @spec get(atom(), term()) :: term()
  def get(key, default \\ nil) do
    Application.get_env(:pincer, key, default)
  end

  @doc """
  Fetches a required configuration value, raising if not found.

  Use this when a configuration value is required for the application
  to function correctly.

  ## Parameters

    - `key` - Atom key to look up in `:pincer` application env

  ## Returns

    - The configured value

  ## Raises

    - `ArgumentError` if the key is not set

  ## Examples

      iex> Pincer.Infra.Config.fetch!(:tokens)
      %{"telegram" => "bot123...", ...}

      iex> Pincer.Infra.Config.fetch!(:nonexistent)
      ** (ArgumentError) could not fetch application environment ...
  """
  @spec fetch!(atom()) :: term()
  def fetch!(key) do
    Application.fetch_env!(:pincer, key)
  end

  defp maybe_put_runtime_override(config, key, env_key, caster \\ & &1) do
    case System.get_env(env_key) do
      nil ->
        config

      "" ->
        config

      value ->
        Keyword.put(config, key, caster.(value))
    end
  end

  @doc """
  Updates the default model for an LLM provider and persists to `config.yaml`.

  This allows hot-swapping models at runtime without restarting the application.
  The configuration is written back to disk and reloaded.

  ## Parameters

    - `model_id` - String identifier of the model to use
    - `provider` - Optional provider name (defaults to current provider)

  ## Returns

    - `{:ok, model_id, provider}` - Successfully updated and reloaded
    - `{:error, reason}` - Failed to read or write config file

  ## Examples

      iex> Pincer.Infra.Config.set_model("gpt-4-turbo")
      {:ok, "gpt-4-turbo", "openrouter"}

      iex> Pincer.Infra.Config.set_model("claude-3-opus", "openrouter")
      {:ok, "claude-3-opus", "openrouter"}

      iex> Pincer.Infra.Config.set_model("model-id")
      {:error, :enoent}  # config.yaml not found
  """
  @spec set_model(String.t(), String.t() | nil) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def set_model(model_id, provider \\ nil) do
    case YamlElixir.read_from_file(@config_file) do
      {:ok, config} ->
        current_provider = provider || Map.get(config["llm"], "provider", "openrouter")

        new_llm =
          config["llm"]
          |> Map.put("provider", current_provider)
          |> put_in([current_provider, "default_model"], model_id)

        new_config = Map.put(config, "llm", new_llm)

        case write_yaml(@config_file, new_config) do
          :ok ->
            load()
            {:ok, model_id, current_provider}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_yaml(path, config) do
    mcp_section =
      if config["mcp"] do
        """
        mcp:
          servers:
            #{Enum.map(config["mcp"]["servers"], fn {name, cfg} -> "#{name}:\n      command: \"#{cfg["command"]}\"\n      args: #{inspect(cfg["args"])}" end) |> Enum.join("\n    ")}
        """
      else
        ""
      end

    content = """
    database:
      adapter: "#{config["database"]["adapter"]}"
      database: "#{config["database"]["database"]}"

    llm:
      provider: "#{config["llm"]["provider"]}"
      opencode_zen:
        base_url: "#{config["llm"]["opencode_zen"]["base_url"]}"
        default_model: "#{config["llm"]["opencode_zen"]["default_model"]}"
      openrouter:
        base_url: "#{config["llm"]["openrouter"]["base_url"]}"
        default_model: "#{config["llm"]["openrouter"]["default_model"]}"
      groq:
        base_url: "#{config["llm"]["groq"]["base_url"]}"
        default_model: "#{config["llm"]["groq"]["default_model"]}"
      groq_whisper:
        base_url: "#{config["llm"]["groq_whisper"]["base_url"]}"
        default_model: "#{config["llm"]["groq_whisper"]["default_model"]}"

    #{mcp_section}
    """

    File.write(path, content)
  end
end
