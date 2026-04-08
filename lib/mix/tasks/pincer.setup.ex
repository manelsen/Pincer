defmodule Mix.Tasks.Pincer.Setup do
  @moduledoc """
  First-run setup wizard. Orchestrates the full bootstrap sequence:

      mix pincer.setup

  Steps (in order):

  1. `mix deps.get`           — install Elixir dependencies
  2. PostgreSQL readiness     — wait up to 15 s for the DB to accept connections
  3. `mix ecto.create`        — create the database (idempotent)
  4. `mix ecto.migrate`       — apply pending migrations
  5. `mix pincer.onboard`     — scaffold config.yaml and workspaces (if needed)

  At the end, `mix pincer.doctor` is invoked automatically by the onboard step.

  ## Options

      --yes / -y            Accept all defaults non-interactively
      --skip-deps           Skip mix deps.get
      --skip-migrations     Skip ecto.create + ecto.migrate
      --reconfigure         Force re-run of mix pincer.onboard even if already configured
      --config path         Config file path (forwarded to onboard, default: config.yaml)

  ## Examples

      mix pincer.setup
      mix pincer.setup --yes
      mix pincer.setup --yes --skip-deps
      mix pincer.setup --yes --reconfigure
  """

  use Mix.Task
  use Boundary, classify_to: Pincer.Mix

  @shortdoc "First-run bootstrap: deps → DB → migrations → onboard"

  @switches [
    yes: :boolean,
    skip_deps: :boolean,
    skip_migrations: :boolean,
    reconfigure: :boolean,
    config: :string
  ]

  @db_retry_interval_ms 1_000
  @db_max_retries 15

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: [y: :yes])

    if invalid != [] do
      flags = Enum.map_join(invalid, ", ", fn {k, _} -> "--#{k}" end)
      Mix.raise("Invalid flags for pincer.setup: #{flags}")
    end

    steps = build_steps(opts)
    total = length(steps)

    Mix.shell().info("\nPincer Setup\n")

    steps
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {{label, fun}, idx}, :ok ->
      Mix.shell().info("[#{idx}/#{total}] #{label}...")

      case fun.() do
        :ok ->
          :ok

        {:skip, reason} ->
          Mix.shell().info("      ↷  #{reason}")

        {:error, message} ->
          Mix.shell().info("\n✗  #{message}")
          {:halt, {:error, message}}
      end

      {:cont, :ok}
    end)
  end

  # ---------------------------------------------------------------------------
  # Steps
  # ---------------------------------------------------------------------------

  defp build_steps(opts) do
    Enum.reject(
      [
        unless(opts[:skip_deps], do: {"Dependências (mix deps.get)", &step_deps/0}),
        unless(opts[:skip_migrations], do: {"PostgreSQL", fn -> step_wait_postgres(opts) end}),
        unless(opts[:skip_migrations],
          do: {"Banco de dados (mix ecto.create)", &step_ecto_create/0}
        ),
        unless(opts[:skip_migrations],
          do: {"Migrações (mix ecto.migrate)", &step_ecto_migrate/0}
        ),
        {"Configuração (mix pincer.onboard)", fn -> step_onboard(opts) end}
      ],
      &is_nil/1
    )
  end

  defp step_deps do
    Mix.Task.run("deps.get", [])
    :ok
  rescue
    e -> {:error, "deps.get falhou: #{Exception.message(e)}"}
  end

  defp step_wait_postgres(opts) do
    config = load_db_config(opts[:config] || "config.yaml")
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

  defp step_onboard(opts) do
    already_configured? = File.exists?(opts[:config] || "config.yaml")

    if already_configured? and not opts[:reconfigure] do
      {:skip, "config.yaml já existe. Use --reconfigure para reconfigurar."}
    else
      onboard_args =
        ["--accept-risk"] ++
          if(opts[:yes], do: ["--non-interactive", "--yes"], else: []) ++
          if(opts[:config], do: ["--config", opts[:config]], else: [])

      Mix.Task.run("pincer.onboard", onboard_args)
      :ok
    end
  rescue
    e -> {:error, "pincer.onboard falhou: #{Exception.message(e)}"}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

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
    with {:ok, content} <- File.read(config_path),
         {:ok, %{"database" => db}} <- YamlElixir.read_from_string(content) do
      db
    else
      _ -> %{}
    end
  end
end
