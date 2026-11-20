defmodule Pincer.Infra.SQLite do
  @moduledoc """
  Embedded zero-infrastructure SQLite3 + FTS5 persistence engine.

  Inspired by Nous Research Hermes Agent's `persistence/sqlite/`:
  - Applies `PRAGMA foreign_keys = ON`, `PRAGMA busy_timeout = 5000`, and on
    file-backed databases `PRAGMA journal_mode = WAL` + `PRAGMA synchronous = NORMAL`
  - Executes idempotent DDL on startup across core storage tables (`messages`,
    `messages_fts` + triggers, `nodes`, `edges`, `documents_fts`, `checkpoints`,
    `pairing_states`) and operational subsystem tables (`self_states`, `lessons`,
    `cron_jobs`, `audit_log`, `dead_letter_queue`)
  - Serializes connection access through an OTP `GenServer` with atomic `BEGIN IMMEDIATE`
    transaction support via `{:sqlite_tx, conn}` handles
  """

  use GenServer
  require Logger

  alias Exqlite.Sqlite3

  @default_db_path "data/pincer.db"
  @sqlite_aliases MapSet.new([
                    "sqlite",
                    "sqlite3",
                    "ecto.adapters.sqlite3",
                    "pincer.storage.adapters.sqlite"
                  ])
  @postgres_aliases MapSet.new([
                      "postgres",
                      "postgresql",
                      "ecto.adapters.postgresql",
                      "pincer.storage.adapters.postgres"
                    ])

  @schema_sql """
  CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    inserted_at TEXT NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_messages_session_id
    ON messages(session_id, id);

  CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts
    USING fts5(content, content='messages', content_rowid='id', tokenize='unicode61');

  CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);
  END;

  CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, content) VALUES ('delete', old.id, old.content);
  END;

  CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, content) VALUES ('delete', old.id, old.content);
    INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);
  END;

  CREATE TABLE IF NOT EXISTS nodes (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    data TEXT NOT NULL,
    embedding TEXT,
    access_count INTEGER NOT NULL DEFAULT 0,
    last_accessed_at TEXT,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_nodes_type ON nodes(type);

  CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts
    USING fts5(node_id UNINDEXED, content, path, tokenize='unicode61');

  CREATE TABLE IF NOT EXISTS edges (
    id TEXT PRIMARY KEY,
    from_id TEXT NOT NULL,
    to_id TEXT NOT NULL,
    type TEXT NOT NULL,
    inserted_at TEXT NOT NULL,
    FOREIGN KEY(from_id) REFERENCES nodes(id) ON DELETE CASCADE,
    FOREIGN KEY(to_id) REFERENCES nodes(id) ON DELETE CASCADE
  );

  CREATE INDEX IF NOT EXISTS idx_edges_from ON edges(from_id, type);
  CREATE INDEX IF NOT EXISTS idx_edges_to ON edges(to_id, type);

  CREATE TABLE IF NOT EXISTS checkpoints (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    task_id TEXT,
    project_id TEXT,
    status TEXT NOT NULL,
    history_snapshot BLOB NOT NULL,
    step_count INTEGER NOT NULL DEFAULT 0,
    metadata TEXT NOT NULL DEFAULT '{}',
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_checkpoints_session ON checkpoints(session_id, status, inserted_at);

  CREATE TABLE IF NOT EXISTS pairing_states (
    channel TEXT NOT NULL,
    sender_id TEXT NOT NULL,
    agent_id TEXT,
    paired_at TEXT NOT NULL,
    raw_data TEXT NOT NULL DEFAULT '{}',
    PRIMARY KEY (channel, sender_id)
  );

  CREATE TABLE IF NOT EXISTS self_states (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL UNIQUE,
    wakefulness TEXT NOT NULL DEFAULT 'idle',
    focus TEXT NOT NULL DEFAULT '',
    concerns TEXT NOT NULL DEFAULT '[]',
    open_questions TEXT NOT NULL DEFAULT '[]',
    work_lanes TEXT NOT NULL DEFAULT '[]',
    last_reflection_summary TEXT NOT NULL DEFAULT '',
    mood_valence REAL NOT NULL DEFAULT 0.0,
    mood_arousal REAL NOT NULL DEFAULT 0.0,
    meta TEXT NOT NULL DEFAULT '{}',
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS lessons (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    content TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'reflection',
    confidence REAL NOT NULL DEFAULT 0.5,
    extraction_confidence REAL NOT NULL DEFAULT 0.5,
    success_count INTEGER NOT NULL DEFAULT 0,
    failure_count INTEGER NOT NULL DEFAULT 0,
    contradiction_penalty REAL NOT NULL DEFAULT 0.0,
    active INTEGER NOT NULL DEFAULT 1,
    last_applied_at TEXT,
    last_outcome TEXT,
    meta TEXT NOT NULL DEFAULT '{}',
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_lessons_agent_active ON lessons(agent_id, active, confidence);

  CREATE TABLE IF NOT EXISTS cron_jobs (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    cron_expression TEXT NOT NULL,
    prompt TEXT NOT NULL,
    session_id TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    next_run_at TEXT,
    last_run_at TEXT,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_cron_jobs_due ON cron_jobs(enabled, next_run_at);

  CREATE TABLE IF NOT EXISTS audit_log (
    id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    actor TEXT,
    target TEXT,
    channel TEXT,
    session_id TEXT,
    outcome TEXT NOT NULL,
    metadata TEXT NOT NULL DEFAULT '{}',
    inserted_at TEXT NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_audit_log_actor ON audit_log(actor, inserted_at);
  CREATE INDEX IF NOT EXISTS idx_audit_log_type ON audit_log(event_type, inserted_at);

  CREATE TABLE IF NOT EXISTS dead_letter_queue (
    id TEXT PRIMARY KEY,
    operation_type TEXT NOT NULL,
    payload TEXT NOT NULL,
    error TEXT,
    attempt_count INTEGER NOT NULL DEFAULT 1,
    last_attempted_at TEXT,
    resolved_at TEXT,
    resolution TEXT,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_dlq_pending ON dead_letter_queue(resolved_at, operation_type, inserted_at);
  """

  # --- Client API ---

  @doc "Starts the SQLite GenServer owning the Exqlite connection."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    server_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc "Returns the configured SQLite GenServer target (or `__MODULE__`)."
  @spec default_server() :: GenServer.server()
  def default_server do
    Application.get_env(:pincer, :sqlite_server) || __MODULE__
  end

  @doc "Returns `true` when `:storage_adapter` is set to `Pincer.Storage.Adapters.SQLite`."
  @spec sqlite_mode?() :: boolean()
  def sqlite_mode? do
    Application.get_env(:pincer, :storage_adapter) ==
      Module.concat(["Pincer", "Storage", "Adapters", "SQLite"])
  end

  @doc "Returns the configured SQLite database file path."
  @spec db_path() :: String.t()
  def db_path do
    Application.get_env(:pincer, :sqlite_path) || @default_db_path
  end

  @doc """
  Parses a raw storage backend identifier into `:sqlite` or `:postgres`.
  """
  @spec parse_storage_backend(term()) ::
          {:ok, :sqlite | :postgres} | :unset | {:error, {:invalid_storage_backend, term()}}
  def parse_storage_backend(nil), do: :unset

  def parse_storage_backend(value) when is_atom(value) do
    value |> Atom.to_string() |> parse_storage_backend()
  end

  def parse_storage_backend(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    cond do
      normalized == "" -> :unset
      MapSet.member?(@sqlite_aliases, normalized) -> {:ok, :sqlite}
      MapSet.member?(@postgres_aliases, normalized) -> {:ok, :postgres}
      true -> {:error, {:invalid_storage_backend, value}}
    end
  end

  def parse_storage_backend(other), do: {:error, {:invalid_storage_backend, other}}

  @doc """
  Resolves the effective storage backend (`:sqlite` or `:postgres`) from env + parsed config map.
  """
  @spec detect_storage_backend(map(), term()) :: :sqlite | :postgres
  def detect_storage_backend(config, env_storage \\ nil)

  def detect_storage_backend(config, env_storage) when is_map(config) do
    candidates = [
      env_storage,
      read_nested_string_or_atom(config, "storage", "adapter"),
      read_nested_string_or_atom(config, "database", "adapter")
    ]

    Enum.find_value(candidates, :postgres, fn candidate ->
      case parse_storage_backend(candidate) do
        {:ok, backend} -> backend
        _ -> nil
      end
    end)
  end

  def detect_storage_backend(_config, env_storage) do
    case parse_storage_backend(env_storage) do
      {:ok, backend} -> backend
      _ -> :postgres
    end
  end

  @doc """
  Validates that `path` is safe (no `..` traversal) and its target/ancestor directory is writable.
  """
  @spec check_writable_path(String.t(), keyword()) :: :ok | {:error, atom()}
  def check_writable_path(path, opts \\ [])

  def check_writable_path(path, opts) when is_binary(path) and is_list(opts) do
    trimmed = String.trim(path)
    root = Keyword.get(opts, :root)

    cond do
      trimmed == "" ->
        {:error, :empty_path}

      trimmed == ":memory:" or String.starts_with?(trimmed, "file::memory:") ->
        :ok

      String.contains?(trimmed, "\0") or Enum.member?(Path.split(trimmed), "..") ->
        {:error, :path_traversal}

      true ->
        expanded =
          if is_binary(root) and Path.type(trimmed) == :relative do
            Path.expand(trimmed, root)
          else
            Path.expand(trimmed)
          end

        if File.dir?(expanded) do
          {:error, :is_directory}
        else
          check_parent_writable(Path.dirname(expanded))
        end
    end
  end

  def check_writable_path(_, _opts), do: {:error, :invalid_path}

  @doc """
  Verifies embedded SQLite3 + FTS5 runtime health on an in-memory connection.
  """
  @spec health_check() :: :ok | {:error, term()}
  def health_check do
    case Sqlite3.open(":memory:") do
      {:ok, conn} ->
        try do
          with :ok <- Sqlite3.execute(conn, "CREATE VIRTUAL TABLE _health_fts USING fts5(x);"),
               :ok <- Sqlite3.execute(conn, "DROP TABLE _health_fts;") do
            :ok
          end
        after
          _ = Sqlite3.close(conn)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_parent_writable(dir) do
    cond do
      File.dir?(dir) ->
        case File.stat(dir) do
          {:ok, %{access: access}} when access in [:read_write, :write] -> :ok
          {:ok, _} -> {:error, :eacces}
          {:error, reason} -> {:error, reason}
        end

      File.exists?(dir) ->
        {:error, :enotdir}

      true ->
        parent = Path.dirname(dir)
        if parent == dir, do: {:error, :enoent}, else: check_parent_writable(parent)
    end
  end

  defp read_nested_string_or_atom(map, section, key) do
    section_atom = if section == "storage", do: :storage, else: :database
    key_atom = :adapter

    sub =
      case Map.get(map, section) do
        nil -> Map.get(map, section_atom)
        val -> val
      end

    if is_map(sub) do
      case Map.get(sub, key) do
        nil -> Map.get(sub, key_atom)
        val -> val
      end
    else
      nil
    end
  end

  @doc "Generates a standard UUID v4 string."
  @spec uuid() :: String.t()
  def uuid, do: Ecto.UUID.generate()

  @doc """
  Decodes a JSON string into an Elixir term, returning `default` on `nil` or invalid input.
  """
  @spec decode_json(term(), term()) :: term()
  def decode_json(json, default \\ %{})

  def decode_json(json, default) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, val} -> val
      _ -> default
    end
  end

  def decode_json(_other, default), do: default

  @doc """
  Parses an ISO8601 UTC timestamp string stored in SQLite into a `DateTime`.
  """
  @spec parse_datetime(term()) :: DateTime.t() | nil
  def parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  def parse_datetime(_), do: nil

  @doc """
  Executes a SELECT/PRAGMA query and returns `{:ok, %{columns: cols, rows: rows}}`.
  Accepts either a GenServer server or an in-transaction `{:sqlite_tx, conn}` handle.
  """
  @spec query(GenServer.server() | {:sqlite_tx, Sqlite3.db()}, String.t(), list()) ::
          {:ok, %{columns: [String.t()], rows: [list()]}} | {:error, term()}
  def query(target \\ default_server(), sql, params \\ [])

  def query({:sqlite_tx, conn}, sql, params) when is_binary(sql) and is_list(params) do
    run_query(conn, sql, params)
  end

  def query(server, sql, params) when is_binary(sql) and is_list(params) do
    GenServer.call(server, {:query, sql, params}, 30_000)
  end

  @doc """
  Executes an INSERT/UPDATE/DELETE statement and returns `:ok` or `{:error, reason}`.
  Accepts either a GenServer server or an in-transaction `{:sqlite_tx, conn}` handle.
  """
  @spec execute(GenServer.server() | {:sqlite_tx, Sqlite3.db()}, String.t(), list()) ::
          :ok | {:error, term()}
  def execute(target \\ default_server(), sql, params \\ [])

  def execute({:sqlite_tx, conn}, sql, params) when is_binary(sql) and is_list(params) do
    run_execute(conn, sql, params)
  end

  def execute(server, sql, params) when is_binary(sql) and is_list(params) do
    GenServer.call(server, {:execute, sql, params}, 30_000)
  end

  @doc """
  Runs `fun` inside a `BEGIN IMMEDIATE` transaction passing a `{:sqlite_tx, conn}` handle.
  Commits on `:ok` or `{:ok, value}`; rolls back on `{:error, reason}` or raised exception.
  """
  @spec transaction(GenServer.server(), ({:sqlite_tx, Sqlite3.db()} -> term())) :: term()
  def transaction(server \\ default_server(), fun) when is_function(fun, 1) do
    GenServer.call(server, {:transaction, fun}, 30_000)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :db_path) || db_path()

    with :ok <- ensure_parent_dir(path),
         {:ok, conn} <- Sqlite3.open(path),
         :ok <- apply_pragmas(conn, path),
         :ok <- Sqlite3.execute(conn, @schema_sql) do
      Logger.info("[SQLITE] Initialized SQLite storage at #{path}")
      {:ok, %{conn: conn, db_path: path}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:query, sql, params}, _from, state) do
    {:reply, run_query(state.conn, sql, params), state}
  end

  @impl true
  def handle_call({:execute, sql, params}, _from, state) do
    {:reply, run_execute(state.conn, sql, params), state}
  end

  @impl true
  def handle_call({:transaction, fun}, _from, state) do
    conn = state.conn

    reply =
      with :ok <- Sqlite3.execute(conn, "BEGIN IMMEDIATE;") do
        try do
          result = fun.({:sqlite_tx, conn})

          case result do
            {:error, _} = err ->
              _ = Sqlite3.execute(conn, "ROLLBACK;")
              err

            _other ->
              case Sqlite3.execute(conn, "COMMIT;") do
                :ok ->
                  result

                {:error, _} = commit_err ->
                  _ = Sqlite3.execute(conn, "ROLLBACK;")
                  commit_err
              end
          end
        rescue
          e ->
            _ = Sqlite3.execute(conn, "ROLLBACK;")
            {:error, {:exception, e}}
        catch
          kind, reason ->
            _ = Sqlite3.execute(conn, "ROLLBACK;")
            {:error, {kind, reason}}
        end
      end

    {:reply, reply, state}
  end

  @impl true
  def terminate(_reason, %{conn: conn}) do
    _ = Sqlite3.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Private ---

  defp ensure_parent_dir(path) do
    if memory_path?(path) do
      :ok
    else
      path |> Path.dirname() |> File.mkdir_p()
    end
  end

  defp apply_pragmas(conn, path) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA foreign_keys = ON;"),
         :ok <- Sqlite3.execute(conn, "PRAGMA busy_timeout = 5000;") do
      if memory_path?(path) do
        :ok
      else
        with :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode = WAL;"),
             :ok <- Sqlite3.execute(conn, "PRAGMA synchronous = NORMAL;") do
          :ok
        end
      end
    end
  end

  defp memory_path?(path) do
    path == ":memory:" or String.starts_with?(path, "file::memory:")
  end

  defp run_query(conn, sql, params) do
    with_statement(conn, sql, params, fn stmt ->
      with {:ok, cols} <- Sqlite3.columns(conn, stmt),
           {:ok, rows} <- Sqlite3.fetch_all(conn, stmt) do
        {:ok, %{columns: cols, rows: rows}}
      end
    end)
  end

  defp run_execute(conn, sql, params) do
    with_statement(conn, sql, params, fn stmt ->
      with {:ok, _rows} <- Sqlite3.fetch_all(conn, stmt) do
        :ok
      end
    end)
  end

  defp with_statement(conn, sql, params, fun) do
    case Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        try do
          with :ok <- Sqlite3.bind(stmt, params) do
            fun.(stmt)
          end
        rescue
          e -> {:error, Exception.message(e)}
        after
          _ = Sqlite3.release(conn, stmt)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
