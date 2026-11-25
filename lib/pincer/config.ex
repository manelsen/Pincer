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

      storage:
        adapter: "sqlite"
        path: "data/pincer.db"
        vec: "auto"
        vec_path: "priv/sqlite_vec/vec0.so"

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
  @sandbox_transports ~w(os tool_registry bwrap)

  @allowed_top_level_keys %{
    "agents" => :agents,
    "channels" => :channels,
    "cluster" => :cluster,
    "cron" => :cron,
    "enable_browser" => :enable_browser,
    "enable_graph_watcher" => :enable_graph_watcher,
    "enable_heartbeat_watchers" => :enable_heartbeat_watchers,
    "enable_skill_promotion" => :enable_skill_promotion,
    "enabled_channels" => :enabled_channels,
    "gateway" => :gateway,
    "health" => :health,
    "health_ip" => :health_ip,
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

  @allowed_storage_keys %{
    "adapter" => :adapter,
    "path" => :path,
    "vec" => :vec,
    "vec_dimensions" => :vec_dimensions,
    "vec_path" => :vec_path
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

        configure_storage(config)

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
    sandbox_config = config["sandbox"] |> apply_sandbox_transport_override()

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

  defp apply_sandbox_transport_override(config) when is_map(config) do
    case System.get_env("PINCER_SANDBOX_TRANSPORT") do
      value when is_binary(value) and value != "" ->
        transport = String.trim(value)

        if transport in @sandbox_transports do
          local = if is_map(config["local"]), do: config["local"], else: %{}
          Map.put(config, "local", Map.put(local, "transport", transport))
        else
          Logger.warning(
            "Ignoring invalid PINCER_SANDBOX_TRANSPORT=#{inspect(transport)}; " <>
              "expected one of #{Enum.join(@sandbox_transports, ", ")}"
          )

          config
        end

      _ ->
        config
    end
  end

  defp apply_sandbox_transport_override(_config), do: nil

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

  defp configure_storage(config) do
    storage_config =
      case config["storage"] do
        value when is_map(value) ->
          value
          |> allowlisted_entries(@allowed_storage_keys, "storage config")
          |> Map.new()

        _ ->
          %{}
      end

    selected =
      first_non_empty([
        System.get_env("PINCER_STORAGE"),
        storage_config[:adapter],
        "sqlite"
      ])

    normalized = selected |> String.trim() |> String.downcase()

    if normalized in ["postgres", "postgresql", "pincer.storage.adapters.postgres"] do
      raise ArgumentError,
            "PostgreSQL storage is no longer supported; set storage.adapter to \"sqlite\""
    end

    unless normalized in [
             "sqlite",
             "sqlite3",
             "pincer.adapters.storage.sqlite",
             "pincer.storage.adapters.sqlite"
           ] do
      raise ArgumentError,
            "Unsupported storage adapter #{inspect(selected)}; only \"sqlite\" is supported"
    end

    Application.put_env(:pincer, :storage_adapter, Pincer.Adapters.Storage.SQLite)

    sqlite_path =
      first_non_empty([
        System.get_env("PINCER_SQLITE_PATH"),
        storage_config[:path],
        "data/pincer.db"
      ])

    Application.put_env(:pincer, :sqlite_path, sqlite_path)

    Application.put_env(
      :pincer,
      :sqlite_vec,
      normalize_vec_setting(storage_config[:vec] || System.get_env("PINCER_SQLITE_VEC"))
    )

    if vec_path = storage_config[:vec_path] || System.get_env("PINCER_SQLITE_VEC_PATH") do
      Application.put_env(:pincer, :sqlite_vec_path, vec_path)
    end

    if dimensions =
         storage_config[:vec_dimensions] || System.get_env("PINCER_SQLITE_VEC_DIMENSIONS") do
      case Integer.parse(to_string(dimensions)) do
        {value, ""} when value > 0 -> Application.put_env(:pincer, :sqlite_vec_dimensions, value)
        _ -> Logger.warning("Ignoring invalid SQLite vector dimension: #{inspect(dimensions)}")
      end
    end
  end

  defp normalize_vec_setting(nil), do: :auto

  defp normalize_vec_setting(value) when is_boolean(value), do: value

  defp normalize_vec_setting(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> :auto
      "auto" -> :auto
      "1" -> true
      "true" -> true
      "yes" -> true
      "0" -> false
      "false" -> false
      "no" -> false
      other -> other
    end
  end

  defp normalize_vec_setting(value), do: value

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

        case write_yaml(@config_file, current_provider, model_id) do
          :ok ->
            # Only the LLM section changed: reload it without re-parsing `.env`
            # or rewriting unrelated runtime configuration.
            load(load_dotenv: false)
            {:ok, model_id, current_provider}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resolves the bind IP address for the `/health` HTTP endpoint.

  Defaults to `{127, 0, 0, 1}` unless overridden via `:health_ip` option/app env
  or `PINCER_HEALTH_IP`.
  """
  @spec health_bind_ip(keyword()) :: :inet.ip_address()
  def health_bind_ip(opts \\ []) when is_list(opts) do
    env_fetcher = Keyword.get(opts, :env_fetcher, &System.get_env/1)

    candidate =
      Keyword.get(opts, :health_ip) ||
        Application.get_env(:pincer, :health_ip) ||
        env_fetcher.("PINCER_HEALTH_IP")

    parse_bind_ip(candidate)
  end

  # Edits the touched `llm` keys in place instead of regenerating the whole file,
  # so unrelated sections (channels, tools, sandbox, ...) survive untouched.
  defp write_yaml(path, provider, model_id) do
    with {:ok, content} <- File.read(path) do
      updated =
        content
        |> put_scalar(["llm", "provider"], provider)
        |> put_scalar(["llm", provider, "default_model"], model_id)

      File.write(path, updated)
    end
  end

  @doc false
  @spec put_scalar(String.t(), [String.t()], String.t()) :: String.t()
  def put_scalar(content, path, value) when is_binary(content) and is_list(path) and path != [] do
    lines = String.split(content, "\n")
    {updated, found?} = rewrite_path(lines, path, value, [])

    if found? do
      Enum.join(updated, "\n")
    else
      Enum.join(append_path(lines, path, value, 0), "\n")
    end
  end

  # Replaces `path` when every key on the way exists.
  defp rewrite_path([line | rest], path, value, acc) do
    indent = leading_spaces(line)

    case match_key(line, path, indent) do
      :no_match ->
        rewrite_path(rest, path, value, [line | acc])

      {:match, sub_path} when length(sub_path) == 1 ->
        {Enum.reverse(acc) ++ [scalar_line(indent, hd(sub_path), value) | rest], true}

      {:match, sub_path} ->
        case rewrite_path(rest, tl(sub_path), value, []) do
          {inner, true} -> {Enum.reverse(acc) ++ [line | inner], true}
          {_inner, false} -> rewrite_path(rest, path, value, [line | acc])
        end
    end
  end

  defp rewrite_path([], _path, _value, acc), do: {Enum.reverse(acc), false}

  # Appends `path` (and any missing intermediate blocks) right after the last
  # line of the deepest existing ancestor block.
  defp append_path(lines, path, value, indent) do
    {missing, insert_at, block_indent} =
      descend_for_append(lines, path, indent, 0, length(lines) - 1)

    addition = build_block(missing, value, block_indent)
    {before, after_block} = Enum.split(lines, insert_at)
    before ++ addition ++ after_block
  end

  defp descend_for_append(lines, [key | rest], indent, start, stop) do
    case find_child(lines, start, stop, indent, key) do
      nil ->
        {[key | rest], max(stop, 0), indent}

      index when rest == [] ->
        {[], index + 1, indent}

      index ->
        block_start = index + 1
        block_stop = max(next_sibling_line(lines, block_start, stop, indent) - 1, index)
        child_indent = child_indent_at(lines, block_start, indent)

        descend_for_append(lines, rest, child_indent, block_start, block_stop)
    end
  end

  defp build_block(path, value, indent) do
    path
    |> Enum.with_index()
    |> Enum.map(fn
      {key, i} when i == length(path) - 1 -> [scalar_line(indent + i * 2, key, value)]
      {key, i} -> [String.duplicate(" ", indent + i * 2) <> key <> ":"]
    end)
    |> List.flatten()
  end

  defp scalar_line(indent, key, value),
    do: String.duplicate(" ", indent) <> key <> ": " <> encode_scalar(value)

  defp match_key(line, [key | _] = path, indent) do
    if leading_spaces(line) == indent and key_matches?(line, key),
      do: {:match, path},
      else: :no_match
  end

  defp find_child(lines, start, stop, indent, key) when start <= stop do
    Enum.find(start..stop//1, fn i ->
      line = Enum.at(lines, i)
      leading_spaces(line) == indent and key_matches?(line, key)
    end)
  end

  defp find_child(_lines, _start, _stop, _indent, _key), do: nil

  defp next_sibling_line(lines, from, stop, indent) when from <= stop do
    Enum.find(from..stop//1, stop + 1, fn i ->
      line = Enum.at(lines, i)
      String.trim(line) != "" and not comment?(line) and leading_spaces(line) <= indent
    end)
  end

  defp next_sibling_line(_lines, _from, stop, _indent), do: stop + 1

  defp child_indent_at(lines, index, fallback) do
    lines
    |> Enum.drop(index)
    |> Enum.reject(&(String.trim(&1) == "" or comment?(&1)))
    |> case do
      [line | _] -> leading_spaces(line)
      [] -> fallback + 2
    end
  end

  defp comment?(line), do: String.starts_with?(String.trim(line), "#")

  defp key_matches?(line, key) do
    stripped = line |> String.trim_leading() |> String.trim_trailing()
    stripped == key <> ":" or String.starts_with?(stripped, key <> ": ")
  end

  defp leading_spaces(line) when is_binary(line) do
    line |> String.to_charlist() |> Enum.take_while(&(&1 == ?\s)) |> length()
  end

  defp encode_scalar(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
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

  defp parse_bind_ip({a, b, c, d} = ip)
       when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
       do: ip

  defp parse_bind_ip({a, b, c, d, e, f, g, h} = ip)
       when a in 0..65_535 and b in 0..65_535 and c in 0..65_535 and d in 0..65_535 and
              e in 0..65_535 and f in 0..65_535 and g in 0..65_535 and h in 0..65_535,
       do: ip

  defp parse_bind_ip(value) when is_binary(value) do
    trimmed = String.trim(value)

    case :inet.parse_address(String.to_charlist(trimmed)) do
      {:ok, ip} -> ip
      {:error, _} -> {127, 0, 0, 1}
    end
  end

  defp parse_bind_ip(_), do: {127, 0, 0, 1}
end
