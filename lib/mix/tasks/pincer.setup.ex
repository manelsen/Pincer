defmodule Mix.Tasks.Pincer.Setup do
  @moduledoc """
  First-run setup wizard for the embedded SQLite backend. Orchestrates the full
  bootstrap sequence:

      mix pincer.setup

  Steps:

  1. `mix deps.get`           — install Elixir dependencies
  2. `mix pincer.onboard`     — scaffold `config.yaml` and workspaces (if needed)
  3. SQLite initialization    — initialize embedded tables, triggers, and FTS5 indices

  ## Options

      --yes / -y            Accept all defaults non-interactively
      --storage mode        Storage backend (only `sqlite` is supported)
      --sqlite-path path    Database file path (default: data/pincer.db)
      --skip-deps           Skip mix deps.get
      --skip-migrations     Skip embedded SQLite initialization
      --reconfigure         Force re-run of mix pincer.onboard even if already configured
      --config path         Config file path (forwarded to onboard, default: config.yaml)
      --root path           Project root for relative paths (default: current directory)

  ## Examples

      mix pincer.setup
      mix pincer.setup --yes
      mix pincer.setup --yes --sqlite-path data/custom.db
      mix pincer.setup --yes --skip-deps --reconfigure
  """

  use Mix.Task
  use Boundary, classify_to: Pincer.Mix

  alias Pincer.Infra.Config
  alias Pincer.Infra.SQLite

  @shortdoc "First-run bootstrap: deps → onboard → embedded SQLite initialization"

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
      :ok ->
        Mix.shell().info("\n✓ Setup concluído.")
        :ok

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @doc false
  @spec build_steps(keyword()) ::
          [{String.t(), (-> :ok | {:skip, String.t()} | {:error, String.t()})}]
  def build_steps(opts) when is_list(opts) do
    validate_storage!(opts[:storage])

    deps_step = unless(opts[:skip_deps], do: {"Dependências (mix deps.get)", &step_deps/0})

    storage_steps = [
      {"Configuração (mix pincer.onboard)", fn -> step_onboard(opts) end},
      unless(opts[:skip_migrations],
        do: {"Banco embutido SQLite", fn -> step_init_sqlite(opts) end}
      )
    ]

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

  defp step_onboard(opts) do
    root = resolve_root(opts)
    config_path = resolve_config_path(opts, root)
    already_configured? = File.exists?(config_path)

    if already_configured? and not opts[:reconfigure] do
      {:skip, "#{config_path} já existe. Use --reconfigure para reconfigurar."}
    else
      onboard_args =
        ["--accept-risk", "--root", root] ++
          if(opts[:yes], do: ["--non-interactive", "--yes"], else: []) ++
          if(opts[:config], do: ["--config", opts[:config]], else: []) ++
          if(opts[:sqlite_path],
            do: ["--sqlite-path", Path.expand(opts[:sqlite_path], root)],
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

  defp validate_storage!(nil), do: :sqlite

  defp validate_storage!(value) do
    case SQLite.parse_storage_backend(value) do
      {:ok, :sqlite} ->
        :sqlite

      _ ->
        Mix.raise(
          "Invalid storage backend for pincer.setup: #{inspect(value)}. Valid values: sqlite"
        )
    end
  end

  defp resolve_root(opts) do
    case opts[:root] do
      nil -> File.cwd!()
      root -> Path.expand(root)
    end
  end

  defp resolve_config_path(opts, root), do: Path.expand(opts[:config] || "config.yaml", root)

  defp resolve_sqlite_path(opts) do
    root = resolve_root(opts)
    config_path = resolve_config_path(opts, root)

    configured_path =
      case Config.load_file(config_path) do
        {:ok, cfg} -> get_in(cfg, ["storage", "path"])
        _ -> nil
      end

    [
      opts[:sqlite_path],
      System.get_env("PINCER_SQLITE_PATH"),
      configured_path,
      @default_sqlite_path
    ]
    |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))
    |> String.trim()
    |> expand_sqlite_path(root)
  end

  defp expand_sqlite_path(path, root) do
    cond do
      path == ":memory:" or String.starts_with?(path, "file::memory:") -> path
      Path.type(path) == :relative -> Path.expand(path, root)
      true -> Path.expand(path)
    end
  end
end
