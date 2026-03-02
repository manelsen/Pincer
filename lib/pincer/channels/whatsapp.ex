defmodule Pincer.Channels.WhatsApp do
  @moduledoc """
  WhatsApp channel adapter backed by a Baileys bridge process.

  The bridge communicates with this adapter through JSONL events/messages over
  stdio. Incoming text is routed to sessions and core command handlers.
  """

  use Pincer.Ports.Channel
  require Logger

  alias Pincer.Core.AccessPolicy
  alias Pincer.Core.Pairing
  alias Pincer.Core.ProjectRouter
  alias Pincer.Core.SessionScopePolicy
  alias Pincer.Core.UX
  alias Pincer.Core.Session.Server

  @default_bridge_module Pincer.Channels.WhatsApp.Bridge.Adapter
  @max_outbound_chunk_chars 3500

  @impl Pincer.Ports.Channel
  def start_link(config) do
    normalized = normalize_map(config)

    if skip_start_in_test_runtime?(normalized) do
      :ignore
    else
      GenServer.start_link(__MODULE__, normalized, name: __MODULE__)
    end
  end

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    config = normalize_map(config)
    Application.put_env(:pincer, :whatsapp_channel_config, config)

    bridge_module = bridge_module(config)

    case bridge_module.start_link(owner: self(), config: config) do
      {:ok, bridge_pid} ->
        Logger.info("[WHATSAPP] Channel started.")

        {:ok,
         %{
           config: config,
           bridge_module: bridge_module,
           bridge_pid: bridge_pid,
           ensure_session_started_fn:
             read_fun(config, "ensure_session_started_fn", &default_ensure_session_started/1),
           ensure_channel_session_fn:
             read_fun(config, "ensure_channel_session_fn", &default_ensure_channel_session/2),
           process_input_fn: read_fun(config, "process_input_fn", &default_process_input/2),
           status_fn: read_fun(config, "status_fn", &default_status/1),
           set_model_fn: read_fun(config, "set_model_fn", &default_set_model/3),
           list_providers_fn:
             read_fun(config, "list_providers_fn", &Pincer.Ports.LLM.list_providers/0),
           list_models_fn: read_fun(config, "list_models_fn", &Pincer.Ports.LLM.list_models/1)
         }}

      :ignore ->
        Logger.warning("[WHATSAPP] Bridge returned :ignore. Channel ignored.")
        :ignore

      {:error, reason} ->
        Logger.warning("[WHATSAPP] Bridge failed to start: #{inspect(reason)}. Channel ignored.")
        :ignore
    end
  end

  @doc """
  Sends a message to a WhatsApp chat via bridge.
  """
  @impl Pincer.Ports.Channel
  def send_message(chat_id, text, _opts \\ []) do
    try do
      GenServer.call(__MODULE__, {:send_message, to_string(chat_id), normalize_text(text)})
    catch
      :exit, _ -> {:error, :channel_unavailable}
    end
  end

  @doc """
  WhatsApp does not support message edits in this v1 adapter; falls back to send.
  """
  @impl Pincer.Ports.Channel
  def update_message(chat_id, _message_id, text) do
    send_message(chat_id, text)
  end

  @impl true
  def handle_call({:send_message, chat_id, text}, _from, state) do
    reply = deliver_message(state, chat_id, text)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:EXIT, bridge_pid, reason}, %{bridge_pid: bridge_pid} = state) do
    Logger.error("[WHATSAPP] Bridge process exited: #{inspect(reason)}")
    {:noreply, %{state | bridge_pid: nil}}
  end

  @impl true
  def handle_info({:whatsapp_bridge_event, event}, state) when is_map(event) do
    {:noreply, handle_bridge_event(event, state)}
  end

  @impl true
  def handle_info({:whatsapp_bridge_exit, status}, state) do
    Logger.error("[WHATSAPP] Bridge exited with status=#{inspect(status)}")
    {:noreply, %{state | bridge_pid: nil}}
  end

  @impl true
  def handle_info(message, state) do
    Logger.debug("[WHATSAPP] Ignoring message: #{inspect(message)}")
    {:noreply, state}
  end

  defp handle_bridge_event(event, state) do
    case read_value(event, "type") do
      "message" ->
        maybe_process_incoming(event, state)
        state

      "ready" ->
        Logger.info("[WHATSAPP] Bridge ready.")
        state

      "qr" ->
        log_qr_guidance(event, state.config)
        state

      "pairing_code" ->
        log_pairing_code_guidance(event)
        state

      "error" ->
        log_bridge_error_guidance(event, state.config)
        state

      other ->
        Logger.debug("[WHATSAPP] Ignoring bridge event type=#{inspect(other)}")
        state
    end
  end

  defp maybe_process_incoming(event, state) do
    chat_id = normalize_text(read_value(event, "chat_id"))
    text = normalize_text(read_value(event, "text"))
    sender_id = normalize_text(read_value(event, "sender_id")) || chat_id
    is_group = truthy?(read_value(event, "is_group"))

    if is_binary(chat_id) and is_binary(text) and String.trim(text) != "" do
      process_incoming(chat_id, sender_id, text, is_group, state)
    else
      Logger.debug("[WHATSAPP] Ignoring malformed inbound message: #{inspect(event)}")
    end
  end

  defp process_incoming(chat_id, sender_id, text, is_group, state) do
    trimmed = String.trim(text)
    session_id = resolve_session_id(chat_id, is_group, state.config)

    cond do
      String.starts_with?(trimmed, "/") ->
        handle_command(chat_id, sender_id, session_id, trimmed, is_group, state)

      true ->
        case UX.resolve_shortcut(trimmed) do
          {:ok, command} ->
            handle_command(chat_id, sender_id, session_id, command, is_group, state)

          :error ->
            case ProjectRouter.continue_if_collecting(session_id, trimmed, has_attachments: false) do
              {:handled, response} ->
                deliver_message(state, chat_id, response)
                maybe_start_project_execution(chat_id, session_id, state)

              :not_handled ->
                route_to_session(chat_id, sender_id, session_id, text, is_group, state)
            end
        end
    end
  end

  defp route_to_session(chat_id, sender_id, session_id, text, is_group, state) do
    case authorize_dm(sender_id, chat_id, is_group, state.config) do
      :allow ->
        with :ok <- safe_apply(state.ensure_session_started_fn, [session_id]),
             :ok <- safe_apply(state.ensure_channel_session_fn, [chat_id, session_id]) do
          case safe_apply(state.process_input_fn, [session_id, text]) do
            {:ok, :started} ->
              :ok

            {:ok, :queued} ->
              :ok

            {:ok, :butler_notified} ->
              :ok

            {:ok, response} when is_binary(response) ->
              deliver_message(state, chat_id, response)

            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning("[WHATSAPP] Failed routing message: #{inspect(reason)}")

            other ->
              Logger.debug("[WHATSAPP] Unexpected process_input return: #{inspect(other)}")
          end
        else
          {:error, reason} ->
            Logger.warning("[WHATSAPP] Session pipeline failed: #{inspect(reason)}")
        end

      {:deny, message} ->
        deliver_message(state, chat_id, message)
    end
  end

  defp maybe_start_project_execution(chat_id, session_id, state) do
    case ProjectRouter.kickoff(session_id) do
      {:ok, kickoff} ->
        with :ok <- safe_apply(state.ensure_session_started_fn, [session_id]),
             :ok <- safe_apply(state.ensure_channel_session_fn, [chat_id, session_id]) do
          deliver_message(state, chat_id, "Project Runner: #{kickoff.status_message}")

          case safe_apply(state.process_input_fn, [session_id, kickoff.prompt]) do
            {:ok, _status} ->
              :ok

            {:error, reason} ->
              Logger.warning("[WHATSAPP] Failed to dispatch project task: #{inspect(reason)}")

            other ->
              Logger.debug("[WHATSAPP] Project task dispatch result: #{inspect(other)}")
          end
        else
          {:error, reason} ->
            Logger.warning("[WHATSAPP] Failed to start project execution: #{inspect(reason)}")
        end

      :not_ready ->
        :ok

      :already_started ->
        :ok

      :completed ->
        :ok
    end
  end

  defp handle_command(chat_id, sender_id, session_id, command_text, is_group, state) do
    {command, args} = split_command(command_text)

    case command do
      "/ping" ->
        deliver_message(state, chat_id, "Pong!")

      "/menu" ->
        deliver_message(state, chat_id, UX.help_text(:generic))

      "/help" ->
        deliver_message(state, chat_id, UX.help_text(:generic))

      "/commands" ->
        deliver_message(state, chat_id, UX.help_text(:generic))

      "/status" ->
        deliver_message(state, chat_id, build_status(state, session_id))

      "/kanban" ->
        deliver_message(state, chat_id, ProjectRouter.kanban(session_id))

      "/project" ->
        seed = if args == "", do: nil, else: args
        deliver_message(state, chat_id, ProjectRouter.project(session_id, seed))
        maybe_start_project_execution(chat_id, session_id, state)

      "/models" ->
        if args == "" do
          deliver_message(state, chat_id, model_help(state))
        else
          handle_model_selection(chat_id, session_id, args, state)
        end

      "/pair" ->
        handle_pairing(chat_id, sender_id, args, is_group, state)

      _ ->
        deliver_message(
          state,
          chat_id,
          "Unknown command: #{command}\n#{UX.unknown_command_hint()}"
        )
    end
  end

  defp handle_model_selection(chat_id, session_id, args, state) do
    case String.split(args, ~r/\s+/, parts: 2) do
      [provider_id, model] when provider_id != "" and model != "" ->
        with :ok <- safe_apply(state.ensure_session_started_fn, [session_id]),
             :ok <- safe_apply(state.set_model_fn, [session_id, provider_id, model]) do
          deliver_message(
            state,
            chat_id,
            "Model configured.\nSession: #{session_id}\nProvider: #{provider_id}\nModel: #{model}"
          )
        else
          {:error, reason} ->
            deliver_message(state, chat_id, "Failed to configure model: #{inspect(reason)}")
        end

      _ ->
        deliver_message(state, chat_id, "Usage: /models <provider> <model>")
    end
  end

  defp handle_pairing(chat_id, sender_id, args, is_group, state) do
    cond do
      is_group ->
        deliver_message(state, chat_id, "Pairing only works in direct messages.")

      args == "" ->
        deliver_message(state, chat_id, "Usage: /pair <codigo>. Solicite o codigo ao operador.")

      true ->
        code = String.trim(args)

        case Pairing.approve_code(:whatsapp, sender_id, code) do
          :ok ->
            deliver_message(
              state,
              chat_id,
              "Pairing concluido com sucesso. Agora sua DM esta autorizada."
            )

          {:error, :not_pending} ->
            deliver_message(
              state,
              chat_id,
              "Nenhum pairing pendente para este usuario. Solicite um novo codigo ao operador."
            )

          {:error, :expired} ->
            deliver_message(
              state,
              chat_id,
              "Codigo de pairing expirado. Solicite um novo codigo ao operador."
            )

          {:error, :invalid_code} ->
            deliver_message(
              state,
              chat_id,
              "Codigo de pairing invalido. Revise o codigo e tente novamente."
            )

          {:error, :attempts_exceeded} ->
            deliver_message(
              state,
              chat_id,
              "Tentativas excedidas para este codigo. Solicite um novo codigo ao operador."
            )
        end
    end
  end

  defp build_status(state, session_id) do
    case safe_apply(state.status_fn, [session_id]) do
      {:ok, status} when is_map(status) ->
        provider =
          case status[:model_override] || status["model_override"] do
            %{provider: provider} -> provider
            %{"provider" => provider} -> provider
            _ -> "Default"
          end

        model =
          case status[:model_override] || status["model_override"] do
            %{model: model} -> model
            %{"model" => model} -> model
            _ -> "Default"
          end

        history_len = status[:history] || status["history"] || []

        state_label =
          if (status[:status] || status["status"]) == :working, do: "Busy", else: "Idle"

        """
        Session Status
        ID: #{session_id}
        Status: #{state_label}
        Provider: #{provider}
        Model: #{model}
        History: #{length(history_len)} messages
        """
        |> String.trim()

      _ ->
        "Could not get session status."
    end
  end

  defp model_help(state) do
    providers = safe_apply(state.list_providers_fn, [])

    case providers do
      list when is_list(list) and list != [] ->
        provider_lines =
          Enum.map(list, fn provider ->
            provider_id = provider[:id] || provider["id"] || "unknown"
            provider_name = provider[:name] || provider["name"] || provider_id

            models =
              case safe_apply(state.list_models_fn, [provider_id]) do
                list when is_list(list) -> list
                _ -> []
              end

            sample_models =
              models
              |> Enum.take(3)
              |> Enum.join(", ")

            "- #{provider_name} (#{provider_id})#{if sample_models != "", do: ": #{sample_models}", else: ""}"
          end)

        ([
           "Model Menu",
           "Use: /models <provider> <model>",
           ""
         ] ++ provider_lines)
        |> Enum.join("\n")

      _ ->
        "No providers available right now."
    end
  end

  defp deliver_message(state, chat_id, text) when is_binary(chat_id) do
    if is_nil(state.bridge_pid) do
      {:error, :bridge_unavailable}
    else
      message = normalize_text(text) || ""

      message
      |> split_outbound_chunks()
      |> Enum.reduce_while(:ok, fn chunk, _acc ->
        case state.bridge_module.send_message(state.bridge_pid, chat_id, chunk) do
          :ok ->
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, reason}}

          _ ->
            {:cont, :ok}
        end
      end)
    end
  end

  defp deliver_message(_state, _chat_id, _text) do
    {:error, :bridge_unavailable}
  end

  defp authorize_dm(_sender_id, _chat_id, true, _config), do: :allow

  defp authorize_dm(sender_id, chat_id, false, config) do
    candidate_id =
      cond do
        is_binary(sender_id) and sender_id != "" -> sender_id
        is_binary(chat_id) and chat_id != "" -> chat_id
        true -> "unknown"
      end

    case AccessPolicy.authorize_dm(:whatsapp, candidate_id, config) do
      {:allow, _meta} -> :allow
      {:deny, %{user_message: message}} -> {:deny, message}
    end
  end

  defp resolve_session_id(chat_id, is_group, config) do
    SessionScopePolicy.resolve(
      :whatsapp,
      %{
        chat_id: chat_id,
        is_group: is_group
      },
      config
    )
  end

  defp split_command(command_text) when is_binary(command_text) do
    case String.split(String.trim(command_text), ~r/\s+/, parts: 2) do
      [command] -> {String.downcase(command), ""}
      [command, args] -> {String.downcase(command), String.trim(args)}
    end
  end

  defp split_command(_), do: {"", ""}

  defp bridge_module(config) do
    read_value(config, "bridge_module") ||
      Application.get_env(:pincer, :whatsapp_bridge, @default_bridge_module)
  end

  defp skip_start_in_test_runtime?(config) do
    Mix.env() == :test and is_nil(read_value(config, "bridge_module")) and
      is_nil(read_value(config, "test_pid"))
  end

  defp log_qr_guidance(event, config) do
    Logger.info("[WHATSAPP] QR received for WhatsApp pairing.")
    Logger.info("[WHATSAPP] WhatsApp Mobile -> Aparelhos conectados -> Conectar um aparelho.")
    Logger.info("[WHATSAPP] Scan the QR shown below in this terminal/log stream.")

    case normalize_text(read_value(event, "ascii")) do
      ascii when is_binary(ascii) and ascii != "" ->
        Logger.info("\n" <> ascii)

      _ ->
        case normalize_text(read_value(event, "qr")) do
          qr when is_binary(qr) and qr != "" ->
            case persist_qr_payload(qr, config) do
              {:ok, path} ->
                Logger.info(
                  "[WHATSAPP] QR payload saved to #{path}. Fallback command: qrencode -t ANSIUTF8 < #{path}"
                )

              {:error, reason} ->
                Logger.warning("[WHATSAPP] Could not persist QR payload: #{inspect(reason)}")
            end

          _ ->
            Logger.warning("[WHATSAPP] QR event without usable payload: #{inspect(event)}")
        end
    end
  end

  defp persist_qr_payload(qr, config) do
    path = qr_artifact_path(config)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, qr <> "\n") do
      {:ok, path}
    end
  end

  defp qr_artifact_path(config) do
    configured =
      config
      |> read_value("bridge")
      |> case do
        bridge when is_map(bridge) -> normalize_text(read_value(bridge, "qr_artifact_path"))
        _ -> nil
      end

    configured || "sessions/whatsapp/last_qr.txt"
  end

  defp log_pairing_code_guidance(event) do
    code = normalize_text(read_value(event, "code"))
    phone = normalize_text(read_value(event, "phone")) || "configured phone"

    if is_binary(code) and code != "" do
      Logger.info("[WHATSAPP] Pairing code ready for #{phone}: #{code}")

      Logger.info(
        "[WHATSAPP] WhatsApp Mobile -> Aparelhos conectados -> Conectar com numero de telefone."
      )

      Logger.info("[WHATSAPP] Enter the code above in your mobile keyboard before expiration.")
    else
      Logger.warning("[WHATSAPP] Pairing code event without code: #{inspect(event)}")
    end
  end

  defp log_bridge_error_guidance(event, config) do
    reason = normalize_text(read_value(event, "reason"))
    details = read_value(event, "details")

    case reason do
      "pairing_code_failed" ->
        phone = normalize_text(read_value(details, "phone")) || "configured phone"
        message = normalize_text(read_value(details, "message")) || "unknown"
        qr_path = qr_artifact_path(config)

        Logger.warning("[WHATSAPP] Pairing code failed for #{phone}: #{message}")

        Logger.info(
          "[WHATSAPP] Fallback to QR is active. WhatsApp Mobile -> Aparelhos conectados -> Conectar um aparelho."
        )

        Logger.info(
          "[WHATSAPP] If QR is not visible, use payload artifact #{qr_path} with: qrencode -t ANSIUTF8 < #{qr_path}"
        )

      _ ->
        Logger.warning("[WHATSAPP] Bridge error event: #{inspect(event)}")
    end
  end

  defp split_outbound_chunks(""), do: []

  defp split_outbound_chunks(message) when is_binary(message) do
    if String.length(message) <= @max_outbound_chunk_chars do
      [message]
    else
      message
      |> String.graphemes()
      |> Enum.chunk_every(@max_outbound_chunk_chars)
      |> Enum.map(&Enum.join/1)
    end
  end

  defp safe_apply(fun, args) when is_function(fun) and is_list(args) do
    try do
      case apply(fun, args) do
        :ok -> :ok
        {:ok, _} = ok -> ok
        {:error, _} = error -> error
        other -> other
      end
    rescue
      error -> {:error, error}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp default_ensure_session_started(session_id) do
    case Registry.lookup(Pincer.Core.Session.Registry, session_id) do
      [] ->
        case Pincer.Core.Session.Supervisor.start_session(session_id) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      [_] ->
        :ok
    end
  end

  defp default_ensure_channel_session(chat_id, session_id) do
    case Pincer.Channels.WhatsApp.Session.ensure_started(chat_id, session_id) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_process_input(session_id, text), do: Server.process_input(session_id, text)
  defp default_status(session_id), do: Pincer.Core.Session.Server.get_status(session_id)

  defp default_set_model(session_id, provider, model) do
    Server.set_model(session_id, provider, model)
    :ok
  end

  defp read_fun(config, key, default) do
    case read_value(config, key) do
      fun when is_function(fun) -> fun
      _ -> default
    end
  end

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_), do: %{}

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp normalize_text(nil), do: nil
  defp normalize_text(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_text(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_text(_), do: nil

  defp read_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {k, value} when is_atom(k) -> if Atom.to_string(k) == key, do: value, else: nil
        _ -> nil
      end)
  end

  defp read_value(_map, _key), do: nil

  defp truthy?(value) when value in [true, "true", 1, "1", true], do: true
  defp truthy?(_), do: false
end
