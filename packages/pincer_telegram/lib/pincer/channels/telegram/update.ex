defmodule Pincer.Channels.Telegram.Update do
  @moduledoc """
  Inbound Telegram update routing and DM policy enforcement.

  Dispatches incoming `callback_query` and `message` updates through
  `Pincer.Channels.Telegram.Menu`, `Pincer.Channels.Telegram.Commands`,
  `Pincer.Channels.Telegram.Media`, and `Pincer.Channels.Shared.Inbound`.
  """

  require Logger

  alias Pincer.Channels.Shared.{Attachments, Inbound, Pairing, ProjectBridge}
  alias Pincer.Channels.Telegram.{Commands, Media, Menu, Session, Transport}

  @doc """
  Safely processes a single Telegram update map, rescuing any unexpected error
  so a malformed payload never crashes the poller.
  """
  @spec process(term()) :: :ok
  def process(update) do
    dispatch(update)
    :ok
  rescue
    error ->
      Logger.error("[TELEGRAM] Failed processing update: #{Exception.message(error)}")
      Logger.debug("[TELEGRAM] Update payload: #{inspect(update)}")
      :ok
  catch
    kind, reason ->
      Logger.error("[TELEGRAM] Failed processing update (#{kind}): #{inspect(reason)}")
      Logger.debug("[TELEGRAM] Update payload: #{inspect(update)}")
      :ok
  end

  @doc """
  Dispatches a Telegram update map by payload type (`callback_query` or `message`).
  """
  @spec dispatch(term()) :: any()
  def dispatch(%{callback_query: callback_query}) when not is_nil(callback_query) do
    data = map_value(callback_query, :data)
    message = map_value(callback_query, :message)

    {chat_id, chat_type, message_id} =
      case message do
        msg when is_map(msg) ->
          chat = map_value(msg, :chat)
          {map_value(chat, :id), map_value(chat, :type), map_value(msg, :message_id)}

        _ ->
          {nil, nil, nil}
      end

    if is_binary(data) and not is_nil(chat_id) and not is_nil(message_id) do
      Menu.handle_callback(chat_id, chat_type, data, message_id)
    else
      Logger.warning(
        "[TELEGRAM] Ignoring malformed callback query: data=#{inspect(data)}, chat_id=#{inspect(chat_id)}, mid=#{inspect(message_id)}"
      )
    end
  end

  def dispatch(%{message: message}) when is_map(message) do
    chat = map_value(message, :chat)
    chat_id = map_value(chat, :id)
    chat_type = map_value(chat, :type)
    text = map_value(message, :text)
    has_attachments = Media.has_supported_attachments?(message)

    if is_nil(chat_id) do
      Logger.debug("Ignoring malformed Telegram message without chat_id: #{inspect(message)}")
    else
      context = Session.context_for_chat(chat_id, chat_type)

      inbound = %{
        text: text,
        has_attachments: has_attachments,
        session_id: context.session_id,
        on_command: fn command -> run_command(chat_id, command, chat_type) end,
        on_message: fn _content -> handle_inbound_message(chat_id, message, chat_type) end,
        on_project_response: fn response, session_id ->
          Commands.send_project_message(chat_id, session_id, response)
          Commands.maybe_start_project_execution(chat_id, context)
        end,
        on_ignored: fn
          :unsupported ->
            Logger.debug("Ignoring unsupported Telegram message payload: #{inspect(message)}")

          _ ->
            Logger.debug("[TELEGRAM] Ignoring message without text/supportable attachments.")
        end
      }

      Inbound.dispatch(inbound,
        resolve_shortcut: &PincerPorts.UX.resolve_shortcut/1,
        continue_project: &ProjectBridge.continue/3
      )
    end
  end

  def dispatch(update) do
    Logger.debug("Ignoring unsupported update or update without text: #{inspect(update)}")
  end

  defp run_command(chat_id, command, chat_type) do
    {cmd, args} = Inbound.split_command(command)
    Commands.handle(chat_id, cmd, args, chat_type)
  end

  # Photos and documents arrive without `text`, so media preparation runs only
  # after the sender passes the DM policy to avoid unauthorized downloads/transcriptions.
  defp handle_inbound_message(chat_id, message, chat_type) do
    if is_nil(map_value(message, :text)) do
      case authorize_private_dm(chat_id, chat_type) do
        :allow -> prepare_and_process(chat_id, message, chat_type)
        {:deny, reason} -> reply_denied(chat_id, reason)
      end
    else
      do_process_message(chat_id, map_value(message, :text), chat_type)
    end
  end

  defp prepare_and_process(chat_id, message, chat_type) do
    case Media.prepare_input_content(message) do
      :empty ->
        Logger.debug("[TELEGRAM] Ignoring message without text or supported attachments.")
        :ok

      {:ok, content} ->
        do_process_message(chat_id, content, chat_type)
    end
  end

  defp do_process_message(chat_id, input_content, chat_type) do
    case authorize_private_dm(chat_id, chat_type) do
      :allow ->
        context = Session.context_for_chat(chat_id, chat_type)
        session_id = context.session_id
        Logger.info("[TELEGRAM] Message received from #{chat_id}")

        Session.ensure_core_started(context)
        Session.ensure_started(chat_id, session_id)

        Logger.info("[TELEGRAM] Routing message to Session ID: #{session_id}")

        incoming = Attachments.to_incoming_message(session_id, input_content)

        case PincerPorts.Session.process_input(session_id, incoming) do
          {:ok, status} when status in [:started, :butler_notified, :buffered, :queued] ->
            :ok

          {:ok, response} when is_binary(response) ->
            Logger.info("[TELEGRAM] Got immediate response, sending back to chat_id: #{chat_id}")
            Transport.send_message(chat_id, response)

          {:ok, other} ->
            Logger.debug(
              "[TELEGRAM] Ignoring process_input success with payload: #{inspect(other)}"
            )

            :ok

          _ ->
            :ok
        end

      {:deny, message} ->
        reply_denied(chat_id, message)
    end
  end

  defp authorize_private_dm(chat_id, chat_type) do
    policy_config = Application.get_env(:pincer, :telegram_channel_config, %{})
    Pairing.authorize_dm(:telegram, chat_id, policy_config, is_dm: chat_type == "private")
  end

  defp reply_denied(chat_id, message) do
    Transport.send_message(chat_id, message, reply_markup: Menu.menu_reply_markup())
  end

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_, _), do: nil
end
