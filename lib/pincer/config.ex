defmodule Pincer.Infra.Config do
  require Logger

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

  @allowed_top_level_keys %{
    "agents" => :agents,
    "channels" => :channels,
    "cluster" => :cluster,
    "cron" => :cron,
    "database" => :database,
    "enable_browser" => :enable_browser,
    "enable_graph_watcher" => :enable_graph_watcher,
    "enable_heartbeat_watchers" => :enable_heartbeat_watchers,
    "enable_skill_promotion" => :enable_skill_promotion,
    "enabled_channels" => :enabled_channels,
    "gateway" => :gateway,
    "health" => :health,
    "health_port" => :health_port,
    "heartbeat" => :heartbeat,
    "hooks" => :hooks,
    "image_provider" => :image_provider,
    "introspection" => :introspection,
    "llm" => :llm,
    "log_mcp" => :log_mcp,
    "log_utc_offset" => :log_utc_offset,
    "max_history_messages" => :max_history_messages,
    "max_recursion_depth" => :max_recursion_depth,
    "mcp" => :mcp,
    "memory" => :memory,
    "memory_window_size" => :memory_window_size,
    "model_router" => :model_router,
    "pairing" => :pairing,
    "rate_limits" => :rate_limits,
    "sandbox" => :sandbox,
    "security" => :security,
    "skills_registry" => :skills_registry,
    "storage" => :storage,
    "tools" => :tools,
    "tts_provider" => :tts_provider,
    "vision_provider" => :vision_provider,
    "webhook" => :webhook,
    "webhook_token" => :webhook_token,
    "workspaces_dir" => :workspaces_dir
  }

  @allowed_ecto_keys %{
    "adapter" => :adapter,
    "backoff_max" => :backoff_max,
    "backoff_min" => :backoff_min,
    "backoff_type" => :backoff_type,
    "connect_timeout" => :connect_timeout,
    "database" => :database,
    "hostname" => :hostname,
    "idle_interval" => :idle_interval,
    "log" => :log,
    "parameters" => :parameters,
    "password" => :password,
    "path" => :path,
    "pool" => :pool,
    "pool_size" => :pool_size,
    "port" => :port,
    "prepare" => :prepare,
    "queue_interval" => :queue_interval,
    "queue_target" => :queue_target,
    "show_sensitive_data_on_connection_error" => :show_sensitive_data_on_connection_error,
    "socket" => :socket,
    "socket_dir" => :socket_dir,
    "ssl" => :ssl,
    "ssl_opts" => :ssl_opts,
    "stacktrace" => :stacktrace,
    "timeout" => :timeout,
    "types" => :types,
    "url" => :url,
    "username" => :username
  }

  @doc """
  Recursively normalizes configuration keys to canonical `snake_case` string keys.

  Preserves structs intact and leaves uppercase environment-variable keys
  (e.g., `"TELEGRAM_BOT_TOKEN"`) untouched. When both a camelCase alias and a
  canonical `snake_case` key exist in the same map, the canonical key wins.
  """
  @spec normalize_keys(term()) :: term()
  def normalize_keys(%_{} = struct), do: struct

  def normalize_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} ->
      normalized_key = normalize_key(key)
      {key_priority(key, normalized_key), normalized_key, normalize_keys(value)}
    end)
    |> Enum.sort_by(fn {priority, _key, _value} -> priority end)
    |> Enum.reduce(%{}, fn {_priority, key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  def normalize_keys(list) when is_list(list), do: Enum.map(list, &normalize_keys/1)
  def normalize_keys(other), do: other

  @doc """
  Reads and normalizes a YAML configuration file at the boundary.
  """
  @spec load_file(String.t()) ::
          {:ok, map()} | {:error, :enoent | :invalid_root | {:yaml_error, term()}}
  def load_file(path) when is_binary(path) do
    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, config} when is_map(config) ->
          {:ok, normalize_keys(config)}

        {:ok, _other} ->
          {:error, :invalid_root}

        {:error, reason} ->
          {:error, {:yaml_error, reason}}
      end
    else
      {:error, :enoent}
    end
  end

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
  @spec load(keyword()) :: :ok | :error
  def load(opts \\ []) do
    config_file = Keyword.get(opts, :config_file, @config_file)
    load_dotenv? = Keyword.get(opts, :load_dotenv, true)

    if load_dotenv? do
      load_dotenv_file()
    end

    previous_llm = Application.get_env(:pincer, :llm, %{}) |> normalize_keys()

    case load_file(config_file) do
      {:ok, config} ->
        config
        |> allowlisted_entries(@allowed_top_level_keys, "config.yaml top-level")
        |> Enum.each(fn {atom_key, value} ->
          Application.put_env(:pincer, atom_key, value)
        end)

        configure_tokens()
        configure_llm(config, previous_llm)
        configure_sandbox(config)

        if intro_config = config["introspection"] do
          Application.put_env(:pincer, :introspection, intro_config)
          Logger.info("Introspection Provider: #{intro_config["provider"] || "default LLM"}")
        end

        if router_config = config["model_router"] do
          Application.put_env(:pincer, :model_router, router_config)
        end

        configure_database(config)

        :ok

      {:error, reason} ->
        Logger.error("Fatal error: Failed to load #{config_file}: #{inspect(reason)}")
        :error
    end
  end

  defp load_dotenv_file do
    Logger.info("Loading environment variables from .env...")

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
        Logger.warning(".env file not found.")
    end
  end

  defp configure_tokens do
    env_telegram = System.get_env("TELEGRAM_BOT_TOKEN")
    env_openrouter = System.get_env("OPENROUTER_API_KEY")
    env_opencode_zen = System.get_env("OPENCODE_ZEN_API_KEY")

    Logger.info(
      "Token ENV Telegram: #{if env_telegram && env_telegram != "", do: "OK", else: "NOT FOUND"}"
    )

    Logger.info(
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
  end

  defp configure_llm(config, previous_llm) do
    if llm_config = config["llm"] do
      merged_llm = Map.merge(previous_llm, llm_config)
      Application.put_env(:pincer, :llm, merged_llm)

      provider = merged_llm["provider"] || "openrouter"
      Application.put_env(:pincer, :default_llm_provider, provider)
      Logger.info("LLM Provider: #{provider}")
    end
  end

  defp configure_sandbox(config) do
    sandbox_config = config["sandbox"]

    if is_map(sandbox_config) do
      Application.put_env(:pincer, :sandbox, sandbox_config)
    end

    adapter_spec =
      case System.get_env("PINCER_SANDBOX_ADAPTER") do
        val when is_binary(val) and val != "" -> String.trim(val)
        _ -> is_map(sandbox_config) && sandbox_config["adapter"]
      end

    case resolve_sandbox_module(adapter_spec) do
      nil -> :ok
      mod -> Application.put_env(:pincer, :sandbox_adapter, mod)
    end
  end

  defp resolve_sandbox_module(spec) when is_binary(spec) do
    case String.downcase(String.trim(spec)) do
      "local" -> Module.concat(["Pincer", "Adapters", "Sandbox", "Local"])
      "docker" -> Module.concat(["Pincer", "Adapters", "Sandbox", "Docker"])
      "ssh" -> Module.concat(["Pincer", "Adapters", "Sandbox", "SSH"])
      _ -> safe_existing_module(spec)
    end
  end

  defp resolve_sandbox_module(_), do: nil

  defp safe_existing_module(spec) do
    parts = spec |> String.trim_leading("Elixir.") |> String.split(".", trim: true)
    if parts != [], do: Module.safe_concat(["Elixir" | parts]), else: nil
  rescue
    ArgumentError -> nil
  end

  defp configure_database(config) do
    db_config = config["database"]
    storage_config = config["storage"]

    if db_config do
      current_repo_config = Application.get_env(:pincer, Pincer.Infra.Repo, [])

      ecto_config =
        db_config
        |> allowlisted_entries(@allowed_ecto_keys, "database config")
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

    configure_storage_adapter(storage_config, db_config)
  end

  defp configure_storage_adapter(storage_config, db_config) do
    env_storage = System.get_env("PINCER_STORAGE")

    storage_adapter =
      if is_map(storage_config), do: storage_config["adapter"], else: nil

    db_adapter = if is_map(db_config), do: db_config["adapter"], else: nil
    selected = first_non_empty([env_storage, storage_adapter, db_adapter])

    sqlite_names = [
      "sqlite",
      "sqlite3",
      "ecto.adapters.sqlite3",
      "pincer.storage.adapters.sqlite"
    ]

    postgres_names = ["postgres", "postgresql", "pincer.storage.adapters.postgres"]

    normalized =
      if is_binary(selected), do: selected |> String.trim() |> String.downcase(), else: nil

    cond do
      normalized in sqlite_names ->
        Application.put_env(
          :pincer,
          :storage_adapter,
          Module.concat(["Pincer", "Storage", "Adapters", "SQLite"])
        )

        sqlite_path =
          first_non_empty([
            System.get_env("PINCER_SQLITE_PATH"),
            is_map(storage_config) && storage_config["path"],
            is_map(db_config) && (db_config["path"] || db_config["database"]),
            "data/pincer.db"
          ])

        Application.put_env(:pincer, :sqlite_path, sqlite_path)

      normalized in postgres_names ->
        Application.put_env(
          :pincer,
          :storage_adapter,
          Module.concat(["Pincer", "Storage", "Adapters", "Postgres"])
        )

      true ->
        :ok
    end
  end

  defp first_non_empty(candidates) do
    Enum.find(candidates, fn
      val when is_binary(val) -> String.trim(val) != ""
      _ -> false
    end)
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

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_key()

  defp normalize_key(key) when is_binary(key) do
    if Regex.match?(~r/\A[A-Z0-9_]+\z/, key) do
      key
    else
      Macro.underscore(key)
    end
  end

  defp normalize_key(key), do: to_string(key)

  defp key_priority(key, normalized_key) when is_binary(key) do
    if key == normalized_key, do: 2, else: 0
  end

  defp key_priority(key, normalized_key) when is_atom(key) do
    if Atom.to_string(key) == normalized_key, do: 1, else: 0
  end

  defp key_priority(_key, _normalized_key), do: 0

  defp allowlisted_entries(map, allowlist, context) do
    map
    |> Enum.reduce([], fn {key, value}, acc ->
      case Map.fetch(allowlist, key) do
        {:ok, atom_key} ->
          [{atom_key, value} | acc]

        :error ->
          Logger.warning("Ignoring unknown #{context} key: #{inspect(key)}")
          acc
      end
    end)
    |> Enum.reverse()
  end
end
