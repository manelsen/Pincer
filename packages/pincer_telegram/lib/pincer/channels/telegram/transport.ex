defmodule Pincer.Channels.Telegram.Transport do
  @moduledoc """
  Outbound Telegram Bot API delivery transport.

  Handles sending messages (with semantic chunking and HTML-to-plain fallback),
  editing messages (with length truncation and parse-error fallback), and
  sending local documents.
  """

  require Logger

  alias Pincer.Channels.Shared.Chunking
  alias Pincer.Channels.Telegram.Formatter

  @max_message_chars 4000
  @chunk_delay_ms 100
  @too_long_descriptions ["Bad Request: message is too long", "Bad Request: text is too long"]

  @doc """
  Returns the configured Telegram API client module.
  """
  @spec api_client() :: module()
  def api_client do
    Application.get_env(:pincer, :telegram_api, Pincer.Channels.Telegram.API.Adapter)
  end

  @doc """
  Sends a text message to a Telegram chat.

  Formats Markdown/HTML unless `skip_formatting: true` is passed in `opts`.
  Automatically splits oversized messages using `Pincer.Channels.Shared.Chunking`
  and falls back to plain text if Telegram rejects HTML entities.
  """
  @spec send_message(String.t() | integer(), String.t(), keyword()) ::
          {:ok, integer() | any()} | {:error, any()}
  def send_message(chat_id, text, opts \\ []) do
    if Keyword.get(opts, :skip_formatting, false) do
      do_send_message(chat_id, text, Keyword.delete(opts, :parse_mode))
    else
      html_text = Formatter.prepare_html(text, opts)
      do_send_message(chat_id, html_text, Keyword.put(opts, :parse_mode, "HTML"))
    end
  end

  @doc """
  Updates an existing Telegram message.
  """
  @spec update_message(String.t() | integer(), integer(), String.t(), keyword()) ::
          :ok | {:error, any()}
  def update_message(chat_id, message_id, text, opts \\ []) do
    if Keyword.get(opts, :skip_formatting, false) do
      edit_plain(chat_id, message_id, text, Keyword.delete(opts, :parse_mode))
    else
      html_text = Formatter.prepare_html(text, opts)
      edit_html(chat_id, message_id, html_text)
    end
  end

  @doc """
  Sends a local file as a document to a Telegram chat.
  """
  @spec send_document(String.t() | integer(), String.t(), keyword()) :: :ok | {:error, any()}
  def send_document(chat_id, file_path, opts \\ []) do
    caption_opts =
      case Keyword.get(opts, :caption) do
        caption when is_binary(caption) and caption != "" -> [caption: caption]
        _ -> []
      end

    case api_client().send_document(chat_id, file_path, caption_opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_send_message(chat_id, text, opts) do
    case api_client().send_message(chat_id, text, opts) do
      {:ok, %{message_id: mid}} ->
        {:ok, mid}

      {:error, %Telegex.Error{description: desc}} when desc in @too_long_descriptions ->
        send_chunked(chat_id, text, opts)

      {:error, %Telegex.Error{description: desc}} ->
        handle_send_error(chat_id, text, opts, desc)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_chunked(chat_id, text, opts) do
    Logger.warning("Telegram message too long. Splitting into semantic chunks...")

    case Chunking.split(text, @max_message_chars, strategy: :lines) do
      [] ->
        {:error, :empty_message}

      [first | rest] ->
        case do_send_message(chat_id, first, opts) do
          {:ok, mid} ->
            Enum.each(rest, fn chunk ->
              Process.sleep(@chunk_delay_ms)
              do_send_message(chat_id, chunk, opts)
            end)

            {:ok, mid}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp handle_send_error(chat_id, text, opts, desc) do
    if Keyword.has_key?(opts, :parse_mode) and Formatter.parse_error?(desc) do
      Logger.warning("Telegram HTML parsing failed. Falling back to plain text. Error: #{desc}")
      plain_text = Formatter.html_to_plain_text(text)
      do_send_message(chat_id, plain_text, Keyword.delete(opts, :parse_mode))
    else
      Logger.error("Telegram terminal failure sending message: #{desc}")
      {:error, desc}
    end
  end

  defp edit_plain(chat_id, message_id, text, opts) do
    case api_client().edit_message_text(chat_id, message_id, text, opts) do
      {:ok, _} -> :ok
      {:error, %Telegex.Error{description: "Bad Request: message is not modified"}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp edit_html(chat_id, message_id, html_text) do
    case api_client().edit_message_text(chat_id, message_id, html_text, parse_mode: "HTML") do
      {:ok, _} ->
        :ok

      {:error, %Telegex.Error{description: "Bad Request: message is not modified"}} ->
        :ok

      {:error, %Telegex.Error{description: desc}} when desc in @too_long_descriptions ->
        edit_html_retry_truncated(chat_id, message_id, Formatter.truncate_html(html_text))

      {:error, %Telegex.Error{description: desc}} ->
        handle_edit_error(chat_id, message_id, html_text, desc)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp edit_html_retry_truncated(chat_id, message_id, truncated) do
    case api_client().edit_message_text(chat_id, message_id, truncated, parse_mode: "HTML") do
      {:ok, _} -> :ok
      {:error, %Telegex.Error{description: "Bad Request: message is not modified"}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_edit_error(chat_id, message_id, html_text, desc) do
    if Formatter.parse_error?(desc) do
      Logger.warning(
        "Telegram HTML update failed. Falling back to plain text update. Error: #{desc}"
      )

      plain_text = Formatter.html_to_plain_text(html_text)
      edit_plain(chat_id, message_id, plain_text, [])
    else
      {:error, desc}
    end
  end
end
