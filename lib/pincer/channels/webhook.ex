defmodule Pincer.Channels.Webhook do
  @moduledoc """
  Universal receive-only webhook channel.

  This channel exposes `ingest/2` as a generic entrypoint for external events
  and routes accepted payloads into `Pincer.Session.Server`.
  """

  use Pincer.Channel
  require Logger

  @default_source "external"
  @default_session_id "webhook_main"
  @default_max_dedup 1_000
  @text_leaf_keys ~w(text content prompt body message)
  @text_container_keys ~w(message event data body payload)
  @source_keys ~w(source provider origin)
  @sender_keys ~w(sender_id user_id chat_id author_id)
  @session_id_keys ~w(session_id session)
  @event_id_keys ~w(event_id delivery_id id)

  @type ingest_status :: :accepted | :duplicate
  @type ingest_response ::
          {:ok, %{status: ingest_status(), session_id: String.t()}} | {:error, atom()}

  @doc """
  Starts the webhook channel.

  `token_env` is mandatory. If it is missing or empty, startup is ignored to
  preserve a fail-closed posture.
  """
  @spec start_link(map()) :: GenServer.on_start() | :ignore
  @impl Pincer.Channel
  def start_link(config) do
    case resolve_token(config) do
      {:ok, token} ->
        GenServer.start_link(__MODULE__, {config, token}, name: __MODULE__)

      {:error, :missing_token_env} ->
        Logger.warning("[WEBHOOK] token_env is required; channel ignored.")
        :ignore

      {:error, {:missing_token_env, env_var}} ->
        Logger.warning("[WEBHOOK] Missing token env #{env_var}; channel ignored.")
        :ignore
    end
  end

  @doc """
  Ingests one webhook payload into the channel runtime.
  """
  @spec ingest(map(), keyword()) :: ingest_response()
  def ingest(payload, opts \\ [])

  def ingest(payload, opts) when is_map(payload) and is_list(opts) do
    try do
      GenServer.call(__MODULE__, {:ingest, payload, opts})
    catch
      :exit, {:noproc, _} -> {:error, :channel_unavailable}
      :exit, _ -> {:error, :channel_unavailable}
    end
  end

  def ingest(_payload, _opts), do: {:error, :invalid_payload}

  @impl true
  def init({config, token}) do
    state = %{
      token: token,
      default_source: normalize_component(read_config(config, "default_source", @default_source)),
      default_session_id:
        normalize_session_id(read_config(config, "default_session_id", @default_session_id)),
      session_mode: read_config(config, "session_mode", "per_sender"),
      max_dedup: normalize_max_dedup(read_config(config, "max_dedup", @default_max_dedup)),
      seen_event_ids: MapSet.new(),
      seen_event_order: :queue.new(),
      ensure_session_started_fn:
        read_config(config, "ensure_session_started_fn", &default_ensure_session_started/1),
      process_input_fn: read_config(config, "process_input_fn", &default_process_input/2)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:ingest, payload, opts}, _from, state) do
    session_id = resolve_session_id(payload, state)
    event_id = extract_event_id(payload, opts)

    response =
      with :ok <- authorize(state, opts),
           :ok <- reject_duplicate(state, event_id, session_id),
           {:ok, text} <- extract_text(payload),
           :ok <- ensure_session_started(state, session_id),
           :ok <- process_input(state, session_id, text) do
        new_state = track_event_id(state, event_id)
        {{:ok, %{status: :accepted, session_id: session_id}}, new_state}
      else
        {:duplicate, sid} ->
          {{:ok, %{status: :duplicate, session_id: sid}}, state}

        {:error, reason} ->
          {{:error, reason}, state}
      end

    {reply, new_state} = response
    {:reply, reply, new_state}
  end

  defp authorize(%{token: nil}, _opts), do: :ok

  defp authorize(%{token: expected}, opts) do
    provided = opts[:token] || token_from_headers(Keyword.get(opts, :headers))

    if is_binary(provided) and provided == expected do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp token_from_headers(headers) when is_map(headers) do
    read_map_value(headers, "x-pincer-token") ||
      read_map_value(headers, "authorization")
  end

  defp token_from_headers(_), do: nil

  defp reject_duplicate(_state, nil, _session_id), do: :ok

  defp reject_duplicate(state, event_id, session_id) do
    if MapSet.member?(state.seen_event_ids, event_id) do
      {:duplicate, session_id}
    else
      :ok
    end
  end

  defp extract_text(payload) do
    case find_text(payload) do
      nil -> {:error, :invalid_payload}
      text -> {:ok, text}
    end
  end

  defp find_text(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp find_text(value) when is_list(value), do: Enum.find_value(value, &find_text/1)

  defp find_text(value) when is_map(value) do
    Enum.find_value(@text_leaf_keys, fn key ->
      value
      |> read_map_value(key)
      |> find_text()
    end) ||
      Enum.find_value(@text_container_keys, fn key ->
        value
        |> read_map_value(key)
        |> find_text()
      end)
  end

  defp find_text(_), do: nil

  defp ensure_session_started(state, session_id) do
    call_safe(state.ensure_session_started_fn, [session_id], :session_start_failed)
  end

  defp process_input(state, session_id, text) do
    case call_safe(state.process_input_fn, [session_id, text], :session_process_failed) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp call_safe(fun, args, error_tag) when is_function(fun) do
    try do
      case apply(fun, args) do
        {:error, reason} -> {:error, {error_tag, reason}}
        other -> other
      end
    rescue
      error -> {:error, {error_tag, error}}
    catch
      kind, reason -> {:error, {error_tag, {kind, reason}}}
    end
  end

  defp resolve_session_id(payload, state) do
    explicit =
      @session_id_keys
      |> Enum.find_value(fn key ->
        payload |> read_map_value(key) |> normalize_session_id()
      end)

    cond do
      explicit != nil ->
        explicit

      state.session_mode == "shared" ->
        state.default_session_id

      true ->
        source = resolve_source(payload, state.default_source)
        sender = resolve_sender(payload)

        if sender do
          normalize_session_id("webhook_#{source}_#{sender}")
        else
          state.default_session_id
        end
    end
  end

  defp resolve_source(payload, fallback) do
    @source_keys
    |> Enum.find_value(fn key ->
      payload |> read_map_value(key) |> normalize_component()
    end)
    |> case do
      nil -> fallback
      source -> source
    end
  end

  defp resolve_sender(payload) do
    @sender_keys
    |> Enum.find_value(fn key ->
      payload |> read_map_value(key) |> normalize_component()
    end)
  end

  defp extract_event_id(payload, opts) do
    payload_id =
      Enum.find_value(@event_id_keys, fn key ->
        payload |> read_map_value(key) |> normalize_component()
      end)

    header_id =
      opts
      |> Keyword.get(:headers, %{})
      |> read_map_value("x-pincer-event-id")
      |> normalize_component()

    payload_id || header_id
  end

  defp track_event_id(state, nil), do: state

  defp track_event_id(state, event_id) do
    ids = MapSet.put(state.seen_event_ids, event_id)
    order = :queue.in(event_id, state.seen_event_order)
    {ids, order} = trim_event_cache(ids, order, state.max_dedup)

    %{state | seen_event_ids: ids, seen_event_order: order}
  end

  defp trim_event_cache(ids, order, max_dedup) do
    if :queue.len(order) <= max_dedup do
      {ids, order}
    else
      {{:value, oldest}, rest} = :queue.out(order)
      trim_event_cache(MapSet.delete(ids, oldest), rest, max_dedup)
    end
  end

  defp normalize_component(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_component(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_component(_), do: nil

  defp normalize_session_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> nil
      sid -> sid
    end
  end

  defp normalize_session_id(_), do: nil

  defp normalize_max_dedup(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_dedup(_), do: @default_max_dedup

  defp read_config(config, key, default) when is_map(config) do
    read_map_value(config, key) || default
  end

  defp read_map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {k, v} when is_atom(k) ->
          if Atom.to_string(k) == key, do: v, else: nil

        _ ->
          nil
      end)
  end

  defp read_map_value(_map, _key), do: nil

  defp resolve_token(config) do
    case read_config(config, "token_env", nil) do
      nil ->
        {:error, :missing_token_env}

      env_var when is_binary(env_var) ->
        case System.get_env(env_var) do
          token when is_binary(token) and token != "" -> {:ok, token}
          _ -> {:error, {:missing_token_env, env_var}}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp default_ensure_session_started(session_id) do
    case Registry.lookup(Pincer.Session.Registry, session_id) do
      [{_, _}] ->
        :ok

      [] ->
        case Pincer.Session.Supervisor.start_session(session_id) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp default_process_input(session_id, text) do
    Pincer.Session.Server.process_input(session_id, text)
  end
end
