defmodule Pincer.Channels.Shared.SessionBridge do
  @moduledoc """
  Shared session and worker lifecycle helpers for channel adapters.

  Channel packages run one worker process per active chat/channel and map each
  conversation to a core session process via `PincerPorts.Session` and
  `PincerPorts.PubSub`. This module centralizes the shared Registry lookup,
  worker startup, PubSub subscription/rebinding, and state initialization while
  leaving transport-specific streaming and formatting to each channel adapter.
  """

  alias PincerPorts.Session.Context

  @type channel :: atom()
  @type recipient_id :: term()
  @type already_started_policy :: :error | :ok | :ok_atom

  @doc """
  Builds the Registry key for a channel session worker.
  """
  @spec worker_key(channel(), recipient_id()) :: String.t()
  def worker_key(channel, recipient_id) when is_atom(channel) do
    "#{channel}_session_worker_#{recipient_id}"
  end

  @doc """
  Builds a `{:via, Registry, ...}` tuple for a channel session worker.

  ## Options
  - `:registry` — Registry module/name (defaults to `PincerPorts.Session.registry/0`)
  - `:key` — explicit Registry key (defaults to `worker_key(channel, recipient_id)`)
  """
  @spec via_tuple(channel(), recipient_id(), keyword()) :: {:via, module(), {atom(), term()}}
  def via_tuple(channel, recipient_id, opts \\ []) when is_atom(channel) do
    registry = Keyword.get_lazy(opts, :registry, &PincerPorts.Session.registry/0)
    key = Keyword.get_lazy(opts, :key, fn -> worker_key(channel, recipient_id) end)
    {:via, Registry, {registry, key}}
  end

  @doc """
  Returns the default session ID (`"<channel>_<recipient_id>"`).
  """
  @spec default_session_id(channel(), recipient_id()) :: String.t()
  def default_session_id(channel, recipient_id) when is_atom(channel) do
    "#{channel}_#{recipient_id}"
  end

  @doc """
  Returns `session_id` when it is a non-empty binary, or falls back to
  `default_session_id(channel, recipient_id)`.
  """
  @spec normalize_session_id(channel(), recipient_id(), term()) :: String.t()
  def normalize_session_id(_channel, _recipient_id, session_id)
      when is_binary(session_id) and session_id != "",
      do: session_id

  def normalize_session_id(channel, recipient_id, _other) when is_atom(channel) do
    default_session_id(channel, recipient_id)
  end

  @doc """
  Returns `true` when `session_id` belongs to `channel` (`"<channel>_*"`).
  """
  @spec handles_session?(channel(), term()) :: boolean()
  def handles_session?(channel, session_id) when is_atom(channel) do
    String.starts_with?(to_string(session_id), "#{channel}_")
  end

  @doc """
  Extracts the channel recipient identifier from a prefixed session ID.
  """
  @spec resolve_recipient(channel(), String.t()) :: String.t()
  def resolve_recipient(channel, session_id) when is_atom(channel) do
    prefix = Atom.to_string(channel)

    case String.split(to_string(session_id), "_", parts: 2) do
      [^prefix, recipient_id] -> recipient_id
      _ -> session_id
    end
  end

  @doc """
  Subscribes the calling worker process to the `"session:<session_id>"` topic.
  """
  @spec subscribe(String.t()) :: {:ok, pid()} | {:error, term()}
  def subscribe(session_id) when is_binary(session_id) do
    PincerPorts.PubSub.subscribe("session:#{session_id}")
  end

  @doc """
  Unsubscribes the calling worker process from `"session:<session_id>"`.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(session_id) when is_binary(session_id) do
    PincerPorts.PubSub.unsubscribe("session:#{session_id}")
  end

  @doc """
  Builds initial state for a channel session worker.

  ## Options
  - `:streaming` — when `true`, merges `PincerPorts.Streaming.status_initial_state/0`
    and `PincerPorts.Streaming.stream_initial_state/0` as defaults.
  - `:extra` — additional map fields merged last into the state.
  """
  @spec initial_state(map(), keyword()) :: map()
  def initial_state(base_state, opts \\ []) when is_map(base_state) do
    extra = Keyword.get(opts, :extra, %{})

    streaming_defaults =
      if Keyword.get(opts, :streaming, false) do
        Map.merge(
          PincerPorts.Streaming.status_initial_state(),
          PincerPorts.Streaming.stream_initial_state()
        )
      else
        %{}
      end

    streaming_defaults
    |> Map.merge(base_state)
    |> Map.merge(extra)
  end

  @doc """
  Handles `{:bind_session, session_id}` topic switching inside a channel worker.

  Ignores empty/non-binary IDs and no-ops when already bound to `session_id`.

  ## Options
  - `:on_rebind` — optional `fn state, session_id -> new_state end` callback used
    to rebuild/update state when switching topics (defaults to `%{state | session_id: session_id}`).
  """
  @spec bind_session(map(), term(), keyword()) :: {:noreply, map()}
  def bind_session(state, session_id, opts \\ [])

  def bind_session(state, session_id, opts) when is_binary(session_id) and session_id != "" do
    if state.session_id == session_id do
      {:noreply, state}
    else
      unsubscribe(state.session_id)
      subscribe(session_id)

      next_state =
        case Keyword.get(opts, :on_rebind) do
          fun when is_function(fun, 2) -> fun.(state, session_id)
          _ -> %{state | session_id: session_id}
        end

      {:noreply, next_state}
    end
  end

  def bind_session(state, _invalid_session_id, _opts), do: {:noreply, state}

  @doc """
  Ensures either a core session process (`%Context{}` or binary `session_id`)
  or a per-recipient channel worker (`{channel, recipient_id}`) is started.
  """
  @spec ensure_started(Context.t() | String.t() | {channel(), recipient_id()}, keyword()) ::
          :ok | {:ok, pid()} | {:error, term()}
  def ensure_started(target, opts \\ [])

  def ensure_started(%Context{} = context, opts) do
    session_id = Keyword.get(opts, :session_id, context.session_id)

    start_opts =
      context
      |> Context.to_start_opts()
      |> Keyword.delete(:session_id)

    ensure_session_process(session_id, start_opts, opts)
  end

  def ensure_started(session_id, opts) when is_binary(session_id) do
    start_opts = Keyword.get(opts, :start_opts, [])

    case Keyword.get(opts, :strategy, :start_session) do
      :ensure_started ->
        session_id
        |> PincerPorts.Session.ensure_started(start_opts)
        |> maybe_normalize_result(opts)

      :start_session ->
        ensure_session_process(session_id, start_opts, opts)
    end
  end

  def ensure_started({channel, recipient_id}, opts) when is_atom(channel) do
    session_id = normalize_session_id(channel, recipient_id, Keyword.get(opts, :session_id))
    registry = Keyword.get_lazy(opts, :registry, &PincerPorts.Session.registry/0)
    key = Keyword.get_lazy(opts, :key, fn -> worker_key(channel, recipient_id) end)
    start_worker = Keyword.fetch!(opts, :start_worker)
    rebind? = Keyword.get(opts, :rebind, true)
    already_started = Keyword.get(opts, :already_started, :error)

    case Registry.lookup(registry, key) do
      [] ->
        case invoke_start_worker(start_worker, recipient_id, session_id) do
          {:ok, pid} ->
            started_result(:ok, pid, already_started)

          {:error, {:already_started, pid}} ->
            if rebind?, do: GenServer.cast(pid, {:bind_session, session_id})
            started_result(:already_started, pid, already_started)

          other ->
            other
        end

      [{pid, _value}] ->
        if rebind?, do: GenServer.cast(pid, {:bind_session, session_id})
        started_result(:already_started, pid, already_started)
    end
  end

  defp ensure_session_process(session_id, start_opts, opts) do
    registry = Keyword.get_lazy(opts, :registry, &PincerPorts.Session.registry/0)

    case Registry.lookup(registry, session_id) do
      [] ->
        if on_start = Keyword.get(opts, :on_start), do: on_start.(session_id)

        session_id
        |> PincerPorts.Session.start_session(start_opts)
        |> maybe_normalize_result(opts)

      [_] ->
        :ok
    end
  end

  defp invoke_start_worker(start_worker, recipient_id, session_id)
       when is_function(start_worker, 2),
       do: start_worker.(recipient_id, session_id)

  defp invoke_start_worker(start_worker, recipient_id, _session_id)
       when is_function(start_worker, 1),
       do: start_worker.(recipient_id)

  defp started_result(:ok, _pid, :ok_atom), do: :ok
  defp started_result(:ok, pid, _policy), do: {:ok, pid}
  defp started_result(:already_started, _pid, :ok_atom), do: :ok
  defp started_result(:already_started, pid, :ok), do: {:ok, pid}
  defp started_result(:already_started, pid, :error), do: {:error, {:already_started, pid}}

  defp maybe_normalize_result(result, opts) do
    if Keyword.get(opts, :normalize_result?, false) do
      case result do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        other -> other
      end
    else
      result
    end
  end
end
