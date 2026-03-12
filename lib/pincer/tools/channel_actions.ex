defmodule Pincer.Adapters.Tools.ChannelActions do
  @moduledoc """
  Native channel actions for cross-channel operational messaging.

  This tool starts with a narrow scope on purpose: sending plain messages to
  the current conversation or to an explicitly addressed Telegram, Discord or
  WhatsApp recipient. It builds on top of the existing channel adapters instead
  of reimplementing transport logic inside the agent core.
  """

  @behaviour Pincer.Ports.Tool

  alias Pincer.Core.Bindings
  alias Pincer.Channels.Discord
  alias Pincer.Channels.Telegram
  alias Pincer.Channels.WhatsApp
  alias Pincer.Core.Session.Server

  @type channel :: :telegram | :discord | :whatsapp

  @impl true
  def spec do
    %{
      name: "channel_actions",
      description:
        "Sends operational messages, files, or replies through Telegram, Discord or WhatsApp. If channel and recipient are omitted, uses the current session conversation when possible.",
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            enum: ["send_message", "send_file", "reply_to"],
            description:
              "Channel action: 'send_message' (plain text), 'send_file' (upload a file from workspace), 'reply_to' (reply to a specific message)."
          },
          content: %{
            type: "string",
            description: "Message text (required for 'send_message' and 'reply_to')."
          },
          path: %{
            type: "string",
            description: "Workspace-relative file path (required for 'send_file')."
          },
          caption: %{
            type: "string",
            description: "Optional caption text when sending a file."
          },
          message_id: %{
            type: "string",
            description:
              "ID of the message to reply to (required for 'reply_to'). Telegram: integer as string."
          },
          channel: %{
            type: "string",
            enum: ["telegram", "discord", "whatsapp"],
            description: "Optional explicit target channel."
          },
          recipient: %{
            type: "string",
            description: "Optional explicit recipient/chat/channel id inside the target channel."
          },
          target_session_id: %{
            type: "string",
            description:
              "Optional explicit Pincer session target like telegram_123, discord_456 or whatsapp_551199..."
          }
        },
        required: ["action"]
      }
    }
  end

  @impl true
  def execute(args, context \\ %{}) do
    case Map.get(args, "action") do
      "send_message" -> send_message(args, context)
      "send_file" -> send_file(args, context)
      "reply_to" -> reply_to(args, context)
      action when is_binary(action) -> {:error, "Unsupported channel_actions action: #{action}"}
      _ -> {:error, "Missing or invalid 'action'."}
    end
  end

  defp send_message(args, context) do
    with {:ok, content} <- fetch_required_string(args, "content"),
         {:ok, {channel, recipient}} <- resolve_destination(args, context),
         {:ok, _message_id} <- dispatch(channel, recipient, content, []) do
      {:ok, "Message sent via #{channel} to #{recipient}."}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
      other -> {:error, "Failed to send channel message: #{inspect(other)}"}
    end
  end

  defp send_file(args, context) do
    workspace = Map.get(context, "workspace_path") || File.cwd!()

    with {:ok, rel_path} <- fetch_required_string(args, "path"),
         abs_path = Path.join(workspace, rel_path),
         true <- File.exists?(abs_path) || {:error, "File not found: #{rel_path}"},
         {:ok, binary} <- File.read(abs_path),
         {:ok, {channel, recipient}} <- resolve_destination(args, context) do
      filename = Path.basename(abs_path)
      caption = Map.get(args, "caption", "")
      files = [%{name: filename, body: binary}]

      case dispatch_file(channel, recipient, files, caption) do
        {:ok, _} -> {:ok, "File '#{filename}' sent via #{channel} to #{recipient}."}
        {:error, reason} when is_binary(reason) -> {:error, reason}
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      true -> {:error, "Unexpected error resolving file path."}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
      other -> {:error, "Failed to send file: #{inspect(other)}"}
    end
  end

  defp reply_to(args, context) do
    with {:ok, content} <- fetch_required_string(args, "content"),
         {:ok, message_id} <- fetch_required_string(args, "message_id"),
         {:ok, {channel, recipient}} <- resolve_destination(args, context),
         {:ok, _} <- dispatch(channel, recipient, content, reply_to_message_id: message_id) do
      {:ok, "Reply sent via #{channel} to #{recipient} (re: #{message_id})."}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
      other -> {:error, "Failed to send reply: #{inspect(other)}"}
    end
  end

  defp resolve_destination(%{"target_session_id" => session_id}, _context)
       when is_binary(session_id) do
    case parse_session_target(session_id) do
      {:ok, destination} -> {:ok, destination}
      {:error, _reason} -> {:error, "Could not resolve destination from target_session_id."}
    end
  end

  defp resolve_destination(%{"channel" => channel, "recipient" => recipient}, _context) do
    with {:ok, normalized_channel} <- normalize_channel(channel),
         {:ok, normalized_recipient} <- fetch_non_empty(recipient) do
      {:ok, {normalized_channel, normalized_recipient}}
    else
      {:error, _reason} -> {:error, "Could not resolve destination from channel and recipient."}
    end
  end

  defp resolve_destination(_args, %{"session_id" => session_id}) when is_binary(session_id) do
    with {:ok, state} <- session_server().get_status(session_id),
         {:ok, destination} <- destination_from_session_state(state, session_id) do
      {:ok, destination}
    else
      _ -> {:error, "Could not resolve destination from current session context."}
    end
  end

  defp resolve_destination(_args, _context), do: {:error, "Could not resolve destination."}

  defp destination_from_session_state(%{principal_ref: principal_ref}, _session_id)
       when is_binary(principal_ref) do
    with {:ok, {channel, recipient}} <- Bindings.parse_principal_ref(principal_ref),
         true <- channel in [:telegram, :discord, :whatsapp] do
      {:ok, {channel, recipient}}
    else
      _ -> {:error, :unresolved}
    end
  end

  defp destination_from_session_state(_state, session_id), do: parse_session_target(session_id)

  defp parse_session_target(session_id) do
    case String.split(to_string(session_id), "_", parts: 2) do
      [channel, recipient] when recipient != "" ->
        with {:ok, normalized_channel} <- normalize_channel(channel) do
          {:ok, {normalized_channel, recipient}}
        end

      _ ->
        {:error, :invalid_session_target}
    end
  end

  defp dispatch(:telegram, recipient, content, opts) do
    telegram_adapter().send_message(recipient, content, opts)
  end

  defp dispatch(:discord, recipient, content, opts) do
    discord_adapter().send_message(recipient, content, opts)
  end

  defp dispatch(:whatsapp, recipient, content, opts) do
    whatsapp_adapter().send_message(recipient, content, opts)
  end

  defp dispatch_file(:telegram, recipient, files, caption) do
    telegram_adapter().send_message(recipient, caption, files: files)
  end

  defp dispatch_file(:discord, recipient, files, caption) do
    discord_adapter().send_message(recipient, caption, files: files)
  end

  defp dispatch_file(:whatsapp, _recipient, files, _caption) do
    filename = files |> List.first(%{}) |> Map.get(:name, "file")
    {:error, "File sending is not supported on WhatsApp (file: #{filename})."}
  end

  defp normalize_channel(channel) when is_atom(channel),
    do: normalize_channel(Atom.to_string(channel))

  defp normalize_channel(channel) when is_binary(channel) do
    case channel |> String.trim() |> String.downcase() do
      "telegram" -> {:ok, :telegram}
      "discord" -> {:ok, :discord}
      "whatsapp" -> {:ok, :whatsapp}
      _ -> {:error, :invalid_channel}
    end
  end

  defp normalize_channel(_), do: {:error, :invalid_channel}

  defp fetch_required_string(args, key) do
    args
    |> Map.get(key)
    |> fetch_non_empty()
    |> case do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, "Missing or invalid '#{key}'."}
    end
  end

  defp fetch_non_empty(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :empty}
      text -> {:ok, text}
    end
  end

  defp fetch_non_empty(_), do: {:error, :invalid}

  defp telegram_adapter do
    Application.get_env(:pincer, :channel_actions_adapters, %{})
    |> Map.get(:telegram, Telegram)
  end

  defp discord_adapter do
    Application.get_env(:pincer, :channel_actions_adapters, %{})
    |> Map.get(:discord, Discord)
  end

  defp whatsapp_adapter do
    Application.get_env(:pincer, :channel_actions_adapters, %{})
    |> Map.get(:whatsapp, WhatsApp)
  end

  defp session_server do
    Application.get_env(:pincer, :channel_actions_session_server, Server)
  end
end
