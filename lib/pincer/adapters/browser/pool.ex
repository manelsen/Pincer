defmodule Pincer.Adapters.Browser.Pool do
  @moduledoc """
  Manages the Playwright browser sidecar process (Node.js) via an Erlang Port.

  The sidecar (`priv/browser/server.js`) controls one Chromium browser with
  one page per session. Communication is newline-delimited JSON on stdin/stdout.

  ## Request format (Elixir → Node)

      {"id":"<uuid>","session":"<session_id>","cmd":"<command>",[...args]}

  ## Response format (Node → Elixir)

      {"id":"<uuid>","ok":"<result>"}
      {"id":"<uuid>","error":"<message>"}

  The sidecar is started lazily on the first call and restarted automatically
  if it crashes.
  """

  use GenServer
  require Logger

  @call_timeout 30_000

  defstruct port: nil, pending: %{}, next_id: 1

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Send a browser command to the sidecar. Returns `{:ok, result}` or `{:error, reason}`."
  @spec cmd(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def cmd(session_id, command, args \\ %{}) do
    GenServer.call(__MODULE__, {:cmd, session_id, command, args}, @call_timeout)
  end

  @doc "Close the browser page for a session."
  @spec close_session(String.t()) :: {:ok, String.t()} | {:error, term()}
  def close_session(session_id) do
    cmd(session_id, "close")
  end

  @doc "Ping the sidecar to check liveness."
  @spec ping() :: :ok | {:error, term()}
  def ping do
    case cmd("_", "ping") do
      {:ok, "pong"} -> :ok
      other -> {:error, other}
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}, {:continue, :start_sidecar}}
  end

  @impl true
  def handle_continue(:start_sidecar, state) do
    case open_port() do
      {:ok, port} ->
        Logger.info("[BROWSER POOL] Playwright sidecar started")
        {:noreply, %{state | port: port}}

      {:error, reason} ->
        Logger.warning("[BROWSER POOL] Could not start sidecar: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:cmd, session_id, command, args}, from, state) do
    state = ensure_port(state)

    if state.port == nil do
      {:reply, {:error, :sidecar_unavailable}, state}
    else
      id = Integer.to_string(state.next_id)

      payload =
        Map.merge(args, %{"id" => id, "session" => session_id, "cmd" => command})
        |> Jason.encode!()

      Port.command(state.port, payload <> "\n")

      pending = Map.put(state.pending, id, from)
      {:noreply, %{state | pending: pending, next_id: state.next_id + 1}}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state = process_responses(data, state)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[BROWSER POOL] Sidecar exited with status #{status}. Will restart on next call.")

    # Fail all pending callers
    Enum.each(state.pending, fn {_id, from} ->
      GenServer.reply(from, {:error, :sidecar_crashed})
    end)

    {:noreply, %{state | port: nil, pending: %{}}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.warning("[BROWSER POOL] Sidecar port exited: #{inspect(reason)}")
    Enum.each(state.pending, fn {_id, from} ->
      GenServer.reply(from, {:error, :sidecar_crashed})
    end)

    {:noreply, %{state | port: nil, pending: %{}}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.port, do: Port.close(state.port)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ensure_port(%{port: nil} = state) do
    case open_port() do
      {:ok, port} ->
        Logger.info("[BROWSER POOL] Playwright sidecar restarted")
        %{state | port: port}

      {:error, _reason} ->
        state
    end
  end

  defp ensure_port(state), do: state

  defp open_port do
    node = System.find_executable("node")

    if node == nil do
      {:error, :node_not_found}
    else
      script = Application.app_dir(:pincer, "priv/browser/server.js")

      port =
        Port.open({:spawn_executable, node}, [
          :binary,
          :exit_status,
          :use_stdio,
          {:packet, 0},
          {:line, 1_048_576},
          {:args, [script]}
        ])

      {:ok, port}
    end
  rescue
    e -> {:error, e}
  end

  defp process_responses(data, state) do
    # data may be a single line or partial; we split on newlines
    lines = String.split(to_string(data), "\n", trim: true)

    Enum.reduce(lines, state, fn line, acc ->
      case Jason.decode(line) do
        {:ok, %{"id" => id, "ok" => result}} ->
          {from, pending} = Map.pop(acc.pending, id)
          if from, do: GenServer.reply(from, {:ok, result})
          %{acc | pending: pending}

        {:ok, %{"id" => id, "error" => reason}} ->
          {from, pending} = Map.pop(acc.pending, id)
          if from, do: GenServer.reply(from, {:error, reason})
          %{acc | pending: pending}

        {:error, _} ->
          Logger.debug("[BROWSER POOL] Ignoring non-JSON sidecar output: #{inspect(line)}")
          acc
      end
    end)
  end
end
