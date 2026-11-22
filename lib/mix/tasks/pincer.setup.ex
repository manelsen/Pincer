defmodule Mix.Tasks.Pincer.Setup do
  @moduledoc """
  First-run setup wizard. Orchestrates the full bootstrap sequence:

      mix pincer.setup

  Supports both **PostgreSQL + pgvector** (default) and **Zero-Infra SQLite + FTS5**:

      # Zero-Infra SQLite (no Postgres/Docker required)
      mix pincer.setup --storage sqlite --yes

      # PostgreSQL + pgvector
      mix pincer.setup --storage postgres --yes

  Steps (PostgreSQL mode):

  1. `mix deps.get`           — install Elixir dependencies
  2. PostgreSQL readiness     — wait up to 15 s for the DB to accept connections
  3. `mix ecto.create`        — create the database (idempotent)
  4. `mix ecto.migrate`       — apply pending migrations
  5. `mix pincer.onboard`     — scaffold config.yaml and workspaces (if needed)

  Steps (SQLite mode):

  1. `mix deps.get`           — install Elixir dependencies
  2. Skip PostgreSQL/Ecto     — zero-infra mode needs no external DB server
  3. `mix pincer.onboard`     — scaffold SQLite config.yaml and workspaces
  4. SQLite initialization    — initialize embedded tables, triggers, and FTS5 indices

  ## Options

      --yes / -y            Accept all defaults non-interactively
      --storage mode        Storage backend: sqlite or postgres (auto-detected if omitted)
      --sqlite-path path    Database file path for sqlite mode (default: data/pincer.db)
      --skip-deps           Skip mix deps.get
      --skip-migrations     Skip ecto.create + ecto.migrate (or SQLite init)
      --reconfigure         Force re-run of mix pincer.onboard even if already configured
      --config path         Config file path (forwarded to onboard, default: config.yaml)
      --root path           Project root for relative paths (default: current directory)

  ## Examples

      mix pincer.setup
      mix pincer.setup --yes
      mix pincer.setup --storage sqlite --yes
      mix pincer.setup --yes --skip-deps --reconfigure
  """

  use Mix.Task
  use Boundary, classify_to: Pincer.Mix

  alias Pincer.Infra.Config
  alias Pincer.Infra.SQLite

  @shortdoc "First-run bootstrap: deps → storage setup (Postgres or SQLite) → onboard"

  @switches [
    yes: :boolean,
    storage: :string,
    sqlite_path: :string,
    skip_deps: :boolean,
    skip_migrations: :boolean,
    reconfigure: :boolean,
    config: :string,
    root: :string
  ]

  @db_retry_interval_ms 1_000
  @db_max_retries 15
  @default_sqlite_path "data/pincer.db"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: [y: :yes])

    if invalid != [] do
      flags = Enum.map_join(invalid, ", ", fn {k, _} -> "--#{k}" end)
      Mix.raise("Invalid flags for pincer.setup: #{flags}")
    end

    steps = build_steps(opts)

    Mix.shell().info("\nPincer Setup\n")

    case run_steps(steps) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end

  @doc false
  @spec resolve_storage_mode(keyword(), (String.t() -> String.t() | nil)) :: :sqlite | :postgres
  def resolve_storage_mode(opts, env_fetcher \\ &System.get_env/1) when is_list(opts) do
    case opts[:storage] do
      nil ->
        resolve_from_env_or_config(opts, env_fetcher)

      explicit ->
        case SQLite.parse_storage_backend(explicit) do
          {:ok, backend} ->
            backend

          _ ->
            Mix.raise(
              "Invalid storage backend for pincer.setup: #{inspect(explicit)}. Valid values: sqlite, postgres"
            )
        end
    end
  end

  @doc false
  @spec build_steps(keyword(), (String.t() -> String.t() | nil)) ::
          [{String.t(), (-> :ok | {:skip, String.t()} | {:error, String.t()})}]
  def build_steps(opts, env_fetcher \\ &System.get_env/1) when is_list(opts) do
    mode = resolve_storage_mode(opts, env_fetcher)

    deps_step = unless(opts[:skip_deps], do: {"Dependências (mix deps.get)", &step_deps/0})

    storage_steps =
      case mode do
        :sqlite ->
          [
            {"PostgreSQL",
             fn -> {:skip, "Modo SQLite selecionado — PostgreSQL/Ecto não necessário"} end},
            {"Configuração (mix pincer.onboard)", fn -> step_onboard(opts, :sqlite) end},
            unless(opts[:skip_migrations],
              do: {"Banco embutido SQLite", fn -> step_init_sqlite(opts) end}
            )
          ]

        :postgres ->
          [
            unless(opts[:skip_migrations],
              do: {"PostgreSQL", fn -> step_wait_postgres(opts) end}
            ),
            unless(opts[:skip_migrations],
              do: {"Banco de dados (mix ecto.create)", &step_ecto_create/0}
            ),
            unless(opts[:skip_migrations],
              do: {"Migrações (mix ecto.migrate)", &step_ecto_migrate/0}
            ),
            {"Configuração (mix pincer.onboard)", fn -> step_onboard(opts, :postgres) end}
          ]
      end

    Enum.reject([deps_step | storage_steps], &is_nil/1)
  end

  @doc false
  @spec run_steps([{String.t(), (-> :ok | {:skip, String.t()} | {:error, String.t()})}]) ::
          :ok | {:error, String.t()}
  def run_steps(steps) when is_list(steps) do
    total = length(steps)

    steps
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {{label, fun}, idx}, :ok ->
      Mix.shell().info("[#{idx}/#{total}] #{label}...")

      case fun.() do
        :ok ->
          {:cont, :ok}

        {:skip, reason} ->
          Mix.shell().info("      ↷  #{reason}")
          {:cont, :ok}

        {:error, message} ->
          Mix.shell().error("\n✗  #{message}")
          {:halt, {:error, message}}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Steps
  # ---------------------------------------------------------------------------

  defp step_deps do
    Mix.Task.run("deps.get", [])
    :ok
  rescue
    e -> {:error, "deps.get falhou: #{Exception.message(e)}"}
  end

  defp step_wait_postgres(opts) do
    config = load_db_config(resolve_config_path(opts, resolve_root(opts)))
    host = Map.get(config, "hostname", "localhost")
    port = Map.get(config, "port", 5432)
    port = if is_binary(port), do: String.to_integer(port), else: port

    Mix.shell().info("      Aguardando PostgreSQL em #{host}:#{port}...")
    wait_postgres(host, port, @db_max_retries)
  end

  defp step_ecto_create do
    Mix.Task.run("ecto.create", ["--quiet"])
    :ok
  rescue
    e -> {:error, "ecto.create falhou: #{Exception.message(e)}"}
  end

  defp step_ecto_migrate do
    Mix.Task.run("ecto.migrate", ["--quiet"])
    :ok
  rescue
    e -> {:error, "ecto.migrate falhou: #{Exception.message(e)}"}
  end

  defp step_onboard(opts, mode) do
    root = resolve_root(opts)
    config_path = resolve_config_path(opts, root)
    already_configured? = File.exists?(config_path)

    if already_configured? and not opts[:reconfigure] do
      {:skip, "#{config_path} já existe. Use --reconfigure para reconfigurar."}
    else
      onboard_args =
        ["--accept-risk", "--storage", Atom.to_string(mode), "--root", root] ++
          if(opts[:yes], do: ["--non-interactive", "--yes"], else: []) ++
          if(opts[:config], do: ["--config", opts[:config]], else: []) ++
          if(opts[:sqlite_path],
            do: [
              "--sqlite-path",
              Path.expand(opts[:sqlite_path], root)
            ],
            else: []
          )

      Mix.Task.reenable("pincer.onboard")
      Mix.Task.run("pincer.onboard", onboard_args)
      :ok
    end
  rescue
    e -> {:error, "pincer.onboard falhou: #{Exception.message(e)}"}
  end

  defp step_init_sqlite(opts) do
    sqlite_path = resolve_sqlite_path(opts)

    with :ok <- SQLite.check_writable_path(sqlite_path),
         :ok <- SQLite.health_check(),
         {:ok, pid} <- SQLite.start_link(name: nil, db_path: sqlite_path) do
      GenServer.stop(pid, :normal)
      Mix.shell().info("      ✓ SQLite inicializado em #{sqlite_path}")
      :ok
    else
      {:error, reason} ->
        {:error, "Inicialização do SQLite falhou em #{sqlite_path}: #{inspect(reason)}"}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp resolve_root(opts) do
    case opts[:root] do
      nil -> File.cwd!()
      root -> Path.expand(root)
    end
  end

  defp resolve_config_path(opts, root), do: Path.expand(opts[:config] || "config.yaml", root)

  defp resolve_from_env_or_config(opts, env_fetcher) do
    case SQLite.parse_storage_backend(env_fetcher.("PINCER_STORAGE")) do
      {:ok, backend} ->
        backend

      _ ->
        config_path = resolve_config_path(opts, resolve_root(opts))

        case Config.load_file(config_path) do
          {:ok, config} -> SQLite.detect_storage_backend(config, nil)
          _ -> :postgres
        end
    end
  end

  defp resolve_sqlite_path(opts) do
    config_path = resolve_config_path(opts, resolve_root(opts))

    configured_path =
      case Config.load_file(config_path) do
        {:ok, cfg} ->
          get_in(cfg, ["storage", "path"]) || get_in(cfg, ["database", "path"])

        _ ->
          nil
      end

    Enum.find(
      [
        opts[:sqlite_path],
        System.get_env("PINCER_SQLITE_PATH"),
        configured_path,
        @default_sqlite_path
      ],
      &(is_binary(&1) and String.trim(&1) != "")
    )
    |> String.trim()
  end

  defp wait_postgres(_host, _port, 0) do
    {:error,
     "PostgreSQL não respondeu após #{@db_max_retries} tentativas.\n" <>
       "   Inicie o banco: docker compose up -d postgres"}
  end

  defp wait_postgres(host, port, retries_left) do
    case :gen_tcp.connect(String.to_charlist(host), port, [], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        Mix.shell().info("      ✓ conectado em #{host}:#{port}")
        :ok

      {:error, _} ->
        Process.sleep(@db_retry_interval_ms)
        wait_postgres(host, port, retries_left - 1)
    end
  end

  defp load_db_config(config_path) do
    case Config.load_file(config_path) do
      {:ok, %{"database" => db}} when is_map(db) -> db
      _ -> %{}
    end
  end
end
