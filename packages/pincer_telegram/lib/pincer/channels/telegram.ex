defmodule Pincer.Channels.Telegram do
  # All modules below live in the host pincer project and are available at
  # runtime but not at pincer_telegram compile time.
  @moduledoc """
  Telegram bot channel implementation using the Telegex library.

  This channel provides full Telegram bot integration with:
  - Long polling for receiving updates (messages, callbacks)
  - Message sending via Bot API
  - Inline keyboard support for interactive menus
  - Command handling (/ping, /status, /models)
  - Per-session model selection

  ## Architecture

  This module acts as a Supervisor that starts `UpdatesProvider` as its child.
  The separation allows for clean lifecycle management:

  ```
  Pincer.Channels.Telegram (Supervisor)
  └── Pincer.Channels.Telegram.UpdatesProvider (GenServer - Poller)
  ```

  ## Configuration

  In `config.yaml`:

      channels:
        telegram:
          enabled: true
          adapter: "Pincer.Channels.Telegram"
          token_env: "TELEGRAM_BOT_TOKEN"

  Set the environment variable:

      export TELEGRAM_BOT_TOKEN="your-bot-token"

  If the token is missing, the channel gracefully ignores itself (`:ignore`).

  ## Session Mapping

  Session IDs are resolved by the session scope policy.
  Default behavior keeps per-chat IDs (`telegram_<chat_id>`), while DM chats can
  be configured to use shared `telegram_main`.

  ## Supported Commands

  | Command    | Description                           |
  |------------|---------------------------------------|
  | `/ping`    | Health check (returns "Pong!")        |
  | `/status`  | Show current session status           |
  | `/models`  | Interactive model selection menu      |

  ## Message Flow

  1. UpdatesProvider polls Telegram API every 1 second
  2. Incoming messages are routed to `PincerPorts.Session.process_input/2`
  3. Responses are sent back via `Telegex.send_message/2`

  ## Examples

      # Send a message to a Telegram chat
      Pincer.Channels.Telegram.send_message("123456789", "Hello from Pincer!")

      # Start the channel (normally done by Supervisor)
      Pincer.Channels.Telegram.start_link(%{"token_env" => "TELEGRAM_BOT_TOKEN"})

  ## See Also

  - `Pincer.Channels.Telegram.UpdatesProvider` - The polling GenServer
  - `PincerPorts.Session` - Session message processing
  - `Pincer.LLM.Client` - Model selection integration
  """

  use Supervisor
  @behaviour PincerPorts.Channel
  require Logger
  alias Pincer.Channels.Shared.{Chunking, Formatting}

  @doc """
  Starts the Telegram channel supervisor.

  Initializes the Telegex library with the bot token and starts the
  UpdatesProvider child process. If the token is not configured,
  returns `:ignore` to skip this channel.

  ## Parameters

    - `config` - Configuration map with `"token_env"` key pointing to
                the environment variable containing the bot token

  ## Returns

    - `{:ok, pid}` - Supervisor started successfully
    - `:ignore` - Token not found, channel disabled

  ## Examples

      Pincer.Channels.Telegram.start_link(%{"token_env" => "TELEGRAM_BOT_TOKEN"})
  """
  @spec start_link(config :: map()) :: Supervisor.on_start()
  @impl PincerPorts.Channel
  def start_link(config) do
    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl Supervisor
  def init(config) do
    token_var = Map.get(config, "token_env", "TELEGRAM_BOT_TOKEN")
    token = System.get_env(token_var)

    if token && token != "" do
      Logger.info("Starting Telegram Channel (Token OK)...")
      Application.put_env(:telegex, :token, token)
      Application.put_env(:pincer, :telegram_channel_config, config)

      # We no longer cleanup/register synchronously in init/1 to avoid blocking the supervisor
      # especially during fast hot-reloads of multiple modules.

      children =
        if Mix.env() == :test,
          do: [Pincer.Channels.Telegram.SessionSupervisor],
          else: [
            Pincer.Channels.Telegram.SessionSupervisor,
            Pincer.Channels.Telegram.UpdatesProvider
          ]

      Supervisor.init(children, strategy: :one_for_one)
    else
      Logger.warning("Telegram token not found. Channel ignored.")
      :ignore
    end
  end

  @doc """
  Sends a text message to a Telegram chat.

  This is the implementation of `PincerPorts.Channel.send_message/2` callback.
  Uses Telegex to communicate with the Telegram Bot API.

  ## Parameters

    - `chat_id` - Telegram chat ID (integer or string)
    - `text` - Message content to send

  ## Returns

    - `{:ok, message_id}` - Message sent successfully
    - `{:error, reason}` - Failed to send (API error, network issue, etc.)
  """
  @spec send_message(chat_id :: String.t() | integer(), text :: String.t(), opts :: keyword()) ::
          {:ok, integer()} | {:error, any()}
  @impl PincerPorts.Channel
  def send_message(chat_id, text, opts \\ []) do
    if Keyword.get(opts, :skip_formatting, false) do
      # Plain text mode for streaming performance and safety
      do_send_message(chat_id, text, Keyword.delete(opts, :parse_mode))
    else
      html_text =
        text
        |> Formatting.format_reasoning(opts)
        |> markdown_to_html()

      do_send_message(chat_id, html_text, Keyword.put(opts, :parse_mode, "HTML"))
    end
  end

  @doc """
  Updates an existing Telegram message.
  """
  @impl PincerPorts.Channel
  def update_message(chat_id, message_id, text, opts \\ []) do
    if Keyword.get(opts, :skip_formatting, false) do
      # Plain text update for streaming
      case Pincer.Channels.Telegram.api_client().edit_message_text(
             chat_id,
             message_id,
             text,
             Keyword.delete(opts, :parse_mode)
           ) do
        {:ok, _} -> :ok
        {:error, %Telegex.Error{description: "Bad Request: message is not modified"}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      html_text =
        text
        |> Formatting.format_reasoning(opts)
        |> markdown_to_html()

      case Pincer.Channels.Telegram.api_client().edit_message_text(chat_id, message_id, html_text,
             parse_mode: "HTML"
           ) do
        {:ok, _} ->
          :ok

        {:error, %Telegex.Error{description: "Bad Request: message is not modified"}} ->
          :ok

        {:error, %Telegex.Error{description: desc}}
        when desc in ["Bad Request: message is too long", "Bad Request: text is too long"] ->
          # Text grew too large to fit in one message — truncate with a note and retry
          truncated = String.slice(html_text, 0, 3900) <> "\n…<i>(truncated)</i>"

          case Pincer.Channels.Telegram.api_client().edit_message_text(
                 chat_id,
                 message_id,
                 truncated,
                 parse_mode: "HTML"
               ) do
            {:ok, _} -> :ok
            {:error, %Telegex.Error{description: "Bad Request: message is not modified"}} -> :ok
            {:error, reason} -> {:error, reason}
          end

        {:error, %Telegex.Error{description: desc}} ->
          is_parse_error =
            String.contains?(desc, "can't parse entities") or
              String.contains?(desc, "can't find end tag")

          if is_parse_error do
            Logger.warning(
              "Telegram HTML update failed. Falling back to plain text update. Error: #{desc}"
            )

            plain_text = Formatting.html_to_plain_text(html_text)

            case Pincer.Channels.Telegram.api_client().edit_message_text(
                   chat_id,
                   message_id,
                   plain_text,
                   []
                 ) do
              {:ok, _} -> :ok
              {:error, %Telegex.Error{description: "Bad Request: message is not modified"}} -> :ok
              {:error, reason} -> {:error, reason}
            end
          else
            {:error, desc}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Sends a local file as a document to a Telegram chat.
  """
  def send_document(chat_id, file_path, opts \\ []) do
    caption_opts =
      case Keyword.get(opts, :caption) do
        caption when is_binary(caption) and caption != "" ->
          [caption: caption]

        _ ->
          []
      end

    case api_client().send_document(chat_id, file_path, caption_opts) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_send_message(chat_id, text, opts) do
    case Pincer.Channels.Telegram.api_client().send_message(chat_id, text, opts) do
      {:ok, %{message_id: mid}} ->
        {:ok, mid}

      {:error, %Telegex.Error{description: desc}}
      when desc in ["Bad Request: message is too long", "Bad Request: text is too long"] ->
        Logger.warning("Telegram message too long. Splitting into semantic chunks...")

        # Split into semantic chunks to keep line/tag integrity where possible
        chunks = Chunking.split(text, 4000, strategy: :lines)

        # We return the first chunk's ID to keep the streaming flow if needed
        [first | rest] = chunks

        # Recursive call to do_send_message for chunks, which handles parse errors
        case do_send_message(chat_id, first, opts) do
          {:ok, mid} ->
            Enum.each(rest, fn chunk ->
              Process.sleep(100)
              do_send_message(chat_id, chunk, opts)
            end)

            {:ok, mid}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, %Telegex.Error{description: desc}} ->
        # ONLY attempt fallback if we are currently using a parse_mode (like HTML)
        # Handle "can't parse entities" as well as any other parse error
        is_parse_error =
          String.contains?(desc, "can't parse entities") or
            String.contains?(desc, "can't find end tag")

        if Keyword.has_key?(opts, :parse_mode) and
             (desc in ["Bad Request: Can't parse entities"] or is_parse_error) do
          Logger.warning(
            "Telegram HTML parsing failed. Falling back to plain text. Error: #{desc}"
          )

          plain_text = Formatting.html_to_plain_text(text)

          # Re-call do_send_message WITHOUT the parse_mode
          do_send_message(chat_id, plain_text, Keyword.delete(opts, :parse_mode))
        else
          # If it failed without parse_mode, it's a real API error (e.g., chat_id invalid)
          Logger.error("Telegram terminal failure sending message: #{desc}")
          {:error, desc}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Converts standard Markdown and/or safe HTML into Telegram-compatible HTML.

  This is a universal translation engine that:
  1. Escapes unsafe characters (preventing broken API calls)
  2. Converts Markdown syntax (bold, italic, strike, underline, code, blockquote)
  3. Preserves/reactivates safe HTML tags from the input
  4. Handles nested formatting

  ## Examples

      iex> Pincer.Channels.Telegram.markdown_to_html("**bold** and _italic_")
      "<b>bold</b> and <i>italic</i>"

      iex> Pincer.Channels.Telegram.markdown_to_html("~~strike~~ and __underline__")
      "<s>strike</s> and <u>underline</u>"

      iex> Pincer.Channels.Telegram.markdown_to_html("`inline` and ```\\nblock\\n```")
      "<code>inline</code> and <pre>block</pre>"

      iex> Pincer.Channels.Telegram.markdown_to_html("<b>HTML bold</b> and **MD bold**")
      "<b>HTML bold</b> and <b>MD bold</b>"

      iex> Pincer.Channels.Telegram.markdown_to_html("> Blockquote line")
      "<blockquote>Blockquote line</blockquote>"

  @doc \"""
  Converts standard Markdown and/or safe HTML into Telegram-compatible HTML.
  Uses a Hybrid Fencing strategy:
  1. Protects literal HTML blocks (<pre>, <code>) and tags (<b>, <i>, etc.)
  2. Uses EarmarkParser to parse structural Markdown from the remaining text
  3. Renders the AST via Pincer.Channels.Telegram.Renderer
  4. Unfences the protected HTML for a 100% faithful hybrid output.
  """
  def markdown_to_html(text) do
    Formatting.markdown_to_html(text,
      render_markdown: fn fenced ->
        case EarmarkParser.as_ast(fenced) do
          {:ok, ast, _warnings} ->
            Pincer.Channels.Telegram.Renderer.render(ast)

          {:error, ast, _errors} ->
            Pincer.Channels.Telegram.Renderer.render(ast)
        end
      end
    )
  end

  @doc false
  def register_commands do
    policy = PincerPorts.UX.registerable_commands(:telegram, PincerPorts.UX.commands())

    Enum.each(policy.issues, fn issue ->
      Logger.warning("[TELEGRAM] Command policy issue: #{issue}")
    end)

    case Pincer.Channels.Telegram.api_client().set_my_commands(policy.commands, []) do
      {:ok, true} ->
        Logger.info("[TELEGRAM] Commands registered successfully.")

      {:error, reason} ->
        Logger.warning("[TELEGRAM] Failed to register commands: #{inspect(reason)}")
    end
  end

  @doc """
  Returns Telegram reply markup for menu affordance.

  Default mode is native-first (`remove_keyboard: true`) to avoid duplicated
  menu buttons on Telegram mobile (native menu button + custom keyboard).
  Set `channels.telegram.menu_keyboard: "persistent"` in config to force the
  legacy persistent keyboard.
  """
  @spec menu_reply_markup() :: map()
  def menu_reply_markup do
    case menu_keyboard_mode(Application.get_env(:pincer, :telegram_channel_config, %{})) do
      :persistent ->
        %{
          keyboard: [[%{text: PincerPorts.UX.menu_button_label()}]],
          resize_keyboard: true,
          one_time_keyboard: false,
          is_persistent: true
        }

      :native ->
        %{remove_keyboard: true}
    end
  end

  defp menu_keyboard_mode(config) when is_map(config) do
    mode =
      config["menu_keyboard"] ||
        config[:menu_keyboard] ||
        config["menuKeyboard"] ||
        config[:menuKeyboard]

    case mode do
      "persistent" -> :persistent
      :persistent -> :persistent
      "custom" -> :persistent
      :custom -> :persistent
      _ -> :native
    end
  end

  defp menu_keyboard_mode(_), do: :native

  def api_client do
    Application.get_env(:pincer, :telegram_api, Pincer.Channels.Telegram.API.Adapter)
  end
end

defmodule Pincer.Channels.Telegram.UpdatesProvider do
  alias Pincer.Channels.Shared.{Attachments, Inbound, Pairing}

  @moduledoc """
  GenServer that polls Telegram for updates using long polling.

  This module handles:
  - Periodic polling of the Telegram Bot API
  - Processing incoming messages and callback queries
  - Routing messages to sessions
  - Handling bot commands (/ping, /status, /models)
  - Managing inline keyboard interactions

  ## Polling Strategy

  Uses long polling with a 5-second timeout to minimize API calls while
  maintaining responsiveness. The poll interval between completed polls
  is 1 second.

  ## Update Processing

  Updates are processed based on their type:

  | Update Type        | Handler                 |
  |--------------------|-------------------------|
  | Text message       | `do_process_message/2`  |
  | Command (/...)     | `handle_command/3`      |
  | Callback query     | `handle_callback/3`     |
  | Other              | Logged and ignored      |

  ## Session Management

  Sessions are created on-demand using IDs resolved by
  the session scope policy.

  ## Examples

  The UpdatesProvider is started automatically by the Telegram supervisor:

      # Started internally by Pincer.Channels.Telegram
      Pincer.Channels.Telegram.UpdatesProvider.start_link(nil)
  """

  use GenServer
  require Logger

  @base_poll_interval 1000
  @max_poll_interval 30_000
  @default_offset_path Path.join("sessions", "telegram_update_offset.txt")
  @max_attachment_bytes 104_857_600
  @groq_max_audio_bytes 25_165_824
  @extra_multimodal_mimes %{
    ".log" => "text/plain",
    ".txt" => "text/plain"
  }

  @doc false
  def start_link(opts) do
    opts = if is_list(opts), do: opts, else: []

    offset_path =
      Keyword.get(
        opts,
        :offset_path,
        Application.get_env(:pincer, :telegram_update_offset_path, @default_offset_path)
      )

    GenServer.start_link(
      __MODULE__,
      %{offset: load_offset(offset_path), failures: 0, offset_path: offset_path},
      name: __MODULE__
    )
  end

  @doc false
  def load_offset(path) when is_binary(path) do
    case File.read(path) do
      {:ok, raw} ->
        case Integer.parse(String.trim(raw)) do
          {offset, _rest} when offset >= 0 -> offset
          _ -> 0
        end

      {:error, _reason} ->
        0
    end
  end

  @doc false
  def persist_offset(path, offset) when is_binary(path) and is_integer(offset) and offset >= 0 do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, "#{offset}\n") do
      :ok
    else
      {:error, reason} ->
        Logger.warning("[TELEGRAM] Failed to persist offset to #{path}: #{inspect(reason)}")
        :ok
    end
  end

  @impl GenServer
  def init(state) do
    if Mix.env() != :test do
      Logger.info("Telegram Poller Started (Manual Mode).")

      # Subscribe to outbound message delivery
      PincerPorts.PubSub.subscribe("system:delivery")

      # Asynchronously cleanup and register commands
      Task.start(fn ->
        Pincer.Channels.Telegram.api_client().delete_webhook()
        Pincer.Channels.Telegram.register_commands()
      end)

      schedule_poll(@base_poll_interval)
    end

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:deliver_message, session_id, message}, state) do
    case String.split(session_id, "_", parts: 2) do
      ["telegram", chat_id_str] ->
        # Converts to integer since Telegex expects numbers
        chat_id =
          case Integer.parse(chat_id_str) do
            {id, _} -> id
            :error -> chat_id_str
          end

        Pincer.Channels.Telegram.send_message(chat_id, message)
        {:noreply, state}

      _ ->
        # Not a telegram session, ignore
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    {new_offset, failures} = fetch_updates(state.offset, state.failures, state.offset_path)
    schedule_poll(next_poll_interval(failures))
    {:noreply, %{state | offset: new_offset, failures: failures}}
  end

  @doc false
  @spec next_poll_interval(non_neg_integer()) :: pos_integer()
  def next_poll_interval(failures) when is_integer(failures) and failures <= 0,
    do: @base_poll_interval

  def next_poll_interval(failures) when is_integer(failures) do
    # Exponential backoff to avoid tight polling loops on VPS/network degradation.
    trunc(min(@base_poll_interval * :math.pow(2, failures), @max_poll_interval))
  end

  def next_poll_interval(_), do: @base_poll_interval

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end

  defp fetch_updates(offset, failures, offset_path) do
    case Pincer.Channels.Telegram.api_client().get_updates(offset: offset, timeout: 5) do
      {:ok, updates} ->
        Enum.each(updates, &safe_process_update/1)

        new_offset =
          if Enum.empty?(updates) do
            offset
          else
            List.last(updates).update_id + 1
          end

        if new_offset != offset do
          persist_offset(offset_path, new_offset)
        end

        {new_offset, 0}

      {:error, reason} ->
        next_failures = failures + 1

        PincerPorts.ChannelPolicy.emit_error(reason, %{
          component: :telegram_poller,
          failures: next_failures
        })

        interval_ms = next_poll_interval(next_failures)

        if PincerPorts.ChannelPolicy.classify(:transient, %{reason: reason}) do
          Logger.warning(
            "Telegram polling error: #{inspect(reason)}. Next interval: #{interval_ms}ms"
          )
        else
          Logger.error(
            "Telegram polling error: #{inspect(reason)}. Next interval: #{interval_ms}ms"
          )
        end

        {offset, next_failures}
    end
  end

  defp safe_process_update(update) do
    process_update(update)
  rescue
    error ->
      Logger.error("[TELEGRAM] Failed processing update: #{Exception.message(error)}")
      Logger.debug("[TELEGRAM] Update payload: #{inspect(update)}")
  catch
    kind, reason ->
      Logger.error("[TELEGRAM] Failed processing update (#{kind}): #{inspect(reason)}")
      Logger.debug("[TELEGRAM] Update payload: #{inspect(update)}")
  end

  defp process_update(%{callback_query: callback_query} = _update)
       when not is_nil(callback_query) do
    data = map_value(callback_query, :data)
    message = map_value(callback_query, :message)

    # Robust extraction of chat and message IDs
    {chat_id, chat_type, message_id} =
      case message do
        msg when is_map(msg) ->
          chat = map_value(msg, :chat)
          {map_value(chat, :id), map_value(chat, :type), map_value(msg, :message_id)}

        _ ->
          {nil, nil, nil}
      end

    if is_binary(data) and not is_nil(chat_id) and not is_nil(message_id) do
      handle_callback(chat_id, chat_type, data, message_id)
    else
      Logger.warning(
        "[TELEGRAM] Ignoring malformed callback query: data=#{inspect(data)}, chat_id=#{inspect(chat_id)}, mid=#{inspect(message_id)}"
      )
    end
  end

  defp process_update(%{message: message}) when is_map(message) do
    chat = map_value(message, :chat)
    chat_id = map_value(chat, :id)
    chat_type = map_value(chat, :type)
    text = map_value(message, :text)
    has_attachments = has_supported_attachments?(message)

    if is_nil(chat_id) do
      Logger.debug("Ignoring malformed Telegram message without chat_id: #{inspect(message)}")
    else
      context = session_context_for_chat(chat_id, chat_type)

      inbound = %{
        text: text,
        has_attachments: has_attachments,
        session_id: context.session_id,
        on_command: fn command -> run_command(chat_id, command, chat_type) end,
        on_message: fn _content -> handle_inbound_message(chat_id, message, chat_type) end,
        on_project_response: fn response, session_id ->
          send_project_message(chat_id, session_id, response)
          maybe_start_project_execution(chat_id, context)
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
        continue_project: &Pincer.Channels.Shared.ProjectBridge.continue/3
      )
    end
  end

  defp process_update(update) do
    Logger.debug("Ignoring unsupported update or update without text: #{inspect(update)}")
  end

  defp run_command(chat_id, command, chat_type) do
    {cmd, args} = Inbound.split_command(command)
    handle_command(chat_id, cmd, args, chat_type)
  end

  # Photos and documents arrive without `text`, so routing the raw text field
  # gave `do_process_message/3` a nil and crashed the poller on every media
  # message. Text-only messages keep their text; anything else is prepared from
  # the message itself, and only after the sender passed the DM policy, so a
  # denied sender cannot trigger a download or a transcription.
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
    case prepare_input_content(message) do
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
        context = session_context_for_chat(chat_id, chat_type)
        session_id = context.session_id
        Logger.info("[TELEGRAM] Message received from #{chat_id}")

        ensure_session_started(context)
        Pincer.Channels.Telegram.Session.ensure_started(chat_id, session_id)

        Logger.info("[TELEGRAM] Routing message to Session ID: #{session_id}")

        incoming = Attachments.to_incoming_message(session_id, input_content)

        case PincerPorts.Session.process_input(session_id, incoming) do
          {:ok, :started} ->
            :ok

          {:ok, :butler_notified} ->
            :ok

          {:ok, :buffered} ->
            :ok

          {:ok, :queued} ->
            :ok

          {:ok, response} when is_binary(response) ->
            Logger.info("[TELEGRAM] Got immediate response, sending back to chat_id: #{chat_id}")
            Pincer.Channels.Telegram.send_message(chat_id, response)

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

  # A denied sender still needs the policy explanation (or pairing
  # instructions), so every denial path answers through here.
  defp reply_denied(chat_id, message) do
    Pincer.Channels.Telegram.send_message(chat_id, message,
      reply_markup: Pincer.Channels.Telegram.menu_reply_markup()
    )
  end

  @doc false
  @spec prepare_input_content(map(), module()) :: {:ok, String.t() | [map()]} | :empty
  def prepare_input_content(message, api_client \\ Pincer.Channels.Telegram.api_client())

  def prepare_input_content(message, api_client) when is_map(message) do
    # A plain text message carries no caption, so reading only `caption`
    # reported it as empty and the message was silently dropped.
    base_text =
      message
      |> text_or_caption()
      |> normalize_text()

    {attachment_text, refs} = extract_attachment_parts(message, api_client)
    Attachments.combine_content(base_text, attachment_text, refs)
  end

  def prepare_input_content(_message, _api_client), do: :empty

  defp text_or_caption(message) do
    case map_value(message, :text) do
      text when is_binary(text) -> text
      _ -> map_value(message, :caption)
    end
  end

  defp has_supported_attachments?(message) when is_map(message) do
    has_document?(message) or has_photo?(message) or has_audio?(message)
  end

  defp has_document?(message), do: is_map(map_value(message, :document))

  defp has_photo?(message) do
    case map_value(message, :photo) do
      photos when is_list(photos) -> photos != []
      _ -> false
    end
  end

  defp has_audio?(message) do
    is_map(map_value(message, :voice)) or
      is_map(map_value(message, :audio)) or
      is_map(map_value(message, :video)) or
      is_map(map_value(message, :video_note))
  end

  defp extract_attachment_parts(message, api_client) do
    {text_acc, refs_acc} =
      {"", []}
      |> maybe_collect_document(message, api_client)
      |> maybe_collect_photo(message, api_client)
      |> maybe_collect_audio(message, api_client)

    {String.trim(text_acc), refs_acc}
  end

  defp maybe_collect_audio({text_acc, refs_acc}, message, api_client) do
    audio_obj =
      map_value(message, :voice) ||
        map_value(message, :audio) ||
        map_value(message, :video) ||
        map_value(message, :video_note)

    case audio_obj do
      obj when is_map(obj) ->
        file_id = map_value(obj, :file_id)
        # Check for video types to set proper extension
        ext =
          if map_value(message, :video) || map_value(message, :video_note),
            do: ".mp4",
            else: ".mp3"

        # For audio/voice/video, we try to transcribe it immediately if a whisper provider is available
        case handle_audio_transcription(file_id, ext, api_client) do
          {:ok, transcribed_text} ->
            # Send feedback message so the user can see what was understood
            chat_id = map_value(map_value(message, :chat), :id)

            if chat_id,
              do:
                Pincer.Channels.Telegram.send_message(chat_id, "🎤 <i>\"#{transcribed_text}\"</i>")

            {text_acc <> "\n" <> transcribed_text, refs_acc}

          _ ->
            {text_acc <> "\n[Media content - transcription failed]", refs_acc}
        end

      _ ->
        {text_acc, refs_acc}
    end
  end

  defp handle_audio_transcription(file_id, ext, api_client) do
    with {:ok, file_path} <- resolve_file_path(api_client, file_id),
         token <- Application.get_env(:telegex, :token),
         url <- "https://api.telegram.org/file/bot#{token}/#{file_path}",
         {:ok, response} <- Req.get(url, receive_timeout: 300_000) do
      case response do
        %{status: 200, body: body} when is_binary(body) ->
          # Save temp file with correct extension
          temp_file = "/tmp/pincer_media_#{file_id}#{ext}"

          case File.write(temp_file, body) do
            {:error, reason} ->
              Logger.error("[TELEGRAM] Failed to write temp audio file: #{inspect(reason)}")
              {:error, :write_failed}

            :ok ->
              file_size = byte_size(body)

              result =
                if file_size > @groq_max_audio_bytes do
                  Logger.info(
                    "[TELEGRAM] Media file too large for Groq (#{file_size} bytes). Splitting..."
                  )

                  process_large_audio(temp_file, file_id)
                else
                  # Call LLM Port for transcription
                  PincerPorts.LLM.transcribe_audio(temp_file, provider: "groq_whisper")
                end

              # Clean up
              File.rm(temp_file)
              result
          end

        _ ->
          {:error, :download_failed}
      end
    else
      _ -> {:error, :transcription_failed}
    end
  end

  defp process_large_audio(input_file, file_id) do
    # Create a temporary directory for chunks
    chunk_prefix = "/tmp/pincer_chunk_#{file_id}"

    # Split audio into 10 minute segments (-f segment -segment_time 600)
    # Using mp3 as target format for safety
    case System.cmd("ffmpeg", [
           "-i",
           input_file,
           "-f",
           "segment",
           "-segment_time",
           "600",
           "-c",
           "copy",
           "#{chunk_prefix}_%03d.mp3"
         ]) do
      {_, 0} ->
        # List chunks
        chunks = Path.wildcard("#{chunk_prefix}_*.mp3") |> Enum.sort()

        Logger.info("[TELEGRAM] Audio split into #{length(chunks)} chunks.")

        texts =
          chunks
          |> Enum.map(fn chunk ->
            case PincerPorts.LLM.transcribe_audio(chunk, provider: "groq_whisper") do
              {:ok, text} -> text
              _ -> "[Transcription of chunk failed]"
            end
          end)

        # Cleanup chunks
        Enum.each(chunks, &File.rm/1)

        {:ok, Enum.join(texts, " ")}

      {error, _} ->
        Logger.error("[TELEGRAM] ffmpeg split failed: #{inspect(error)}")
        # Fallback: try to transcribe original file anyway, maybe it's just on the edge
        PincerPorts.LLM.transcribe_audio(input_file, provider: "groq_whisper")
    end
  end

  defp maybe_collect_document({text_acc, refs_acc}, message, api_client) do
    case map_value(message, :document) do
      document when is_map(document) ->
        filename =
          Attachments.sanitize_filename(
            map_value(document, :file_name) || "document",
            "document"
          )

        size = Attachments.normalize_size(map_value(document, :file_size))
        mime = resolve_document_mime(document, filename)
        ext = filename |> Path.extname() |> String.downcase()

        multimodal? =
          Attachments.multimodal_extension?(ext, mime,
            extra_mimes: @extra_multimodal_mimes,
            allow_text_mime: true
          )

        cond do
          Attachments.validate_size(size, @max_attachment_bytes) == {:error, :too_large} ->
            text = Attachments.append_meta(text_acc, filename, size, " (arquivo grande demais)")
            {text, refs_acc}

          not multimodal? ->
            # Non-multimodal documents (zip, csv, json, etc.) — expose as workspace file ref
            # for the session server to download into the workspace incoming/ directory.
            case build_attachment_ref(
                   document,
                   filename,
                   size,
                   mime,
                   api_client,
                   "workspace_file_ref"
                 ) do
              {:ok, workspace_ref} ->
                {text_acc, refs_acc ++ [workspace_ref]}

              {:error, reason} ->
                Logger.warning(
                  "[TELEGRAM] Failed to resolve non-multimodal document '#{filename}': #{inspect(reason)}"
                )

                text =
                  Attachments.append_meta(text_acc, filename, size, " (erro ao resolver arquivo)")

                {text, refs_acc}
            end

          true ->
            case build_attachment_ref(document, filename, size, mime, api_client) do
              {:ok, ref} ->
                {text_acc, refs_acc ++ [ref]}

              {:error, reason} ->
                Logger.warning(
                  "[TELEGRAM] Failed to resolve document attachment '#{filename}': #{inspect(reason)}"
                )

                text =
                  Attachments.append_meta(text_acc, filename, size, " (erro ao resolver arquivo)")

                {text, refs_acc}
            end
        end

      _ ->
        {text_acc, refs_acc}
    end
  end

  defp maybe_collect_photo({text_acc, refs_acc}, message, api_client) do
    case map_value(message, :photo) do
      photos when is_list(photos) and photos != [] ->
        case Attachments.largest_photo(photos) do
          nil ->
            {text_acc, refs_acc}

          photo ->
            size = Attachments.normalize_size(map_value(photo, :file_size))
            unique_id = map_value(photo, :file_unique_id) || map_value(photo, :file_id) || "photo"
            filename = Attachments.sanitize_filename("photo_#{unique_id}.jpg")

            case build_attachment_ref(photo, filename, size, "image/jpeg", api_client) do
              {:ok, ref} ->
                {text_acc, refs_acc ++ [ref]}

              {:error, reason} ->
                Logger.warning(
                  "[TELEGRAM] Failed to resolve photo attachment: #{inspect(reason)}"
                )

                {text_acc, refs_acc}
            end
        end

      _ ->
        {text_acc, refs_acc}
    end
  end

  defp build_attachment_ref(
         file_obj,
         filename,
         size,
         mime,
         api_client,
         type \\ "attachment_ref"
       ) do
    with file_id when is_binary(file_id) <- normalize_binary(map_value(file_obj, :file_id)),
         {:ok, file_path} <- resolve_file_path(api_client, file_id) do
      {:ok,
       Attachments.build_ref("telegram://file/#{file_path}", filename, mime, size, type: type)}
    else
      _ -> {:error, :file_resolution_failed}
    end
  end

  defp resolve_file_path(api_client, file_id) do
    case api_client.get_file(file_id) do
      {:ok, file} ->
        file_path =
          map_value(file, :file_path) ||
            map_value(map_value(file, :result), :file_path)

        case normalize_binary(file_path) do
          nil -> {:error, :missing_file_path}
          path -> {:ok, path}
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_file_response}
    end
  end

  defp resolve_document_mime(document, filename) do
    declared = normalize_binary(map_value(document, :mime_type))
    Attachments.resolve_mime(declared, filename, extra_mimes: @extra_multimodal_mimes)
  end

  defp normalize_text(value) do
    value
    |> normalize_binary()
    |> case do
      nil -> ""
      text -> text
    end
  end

  defp normalize_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  # `nil` is an atom, and `Atom.to_string(nil)` is "nil" - converting it turned
  # an absent caption into the literal text "nil".
  defp normalize_binary(nil), do: nil

  defp normalize_binary(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_binary()

  defp normalize_binary(value) when is_integer(value),
    do: value |> Integer.to_string() |> normalize_binary()

  defp normalize_binary(_), do: nil

  @doc false
  defp handle_command(chat_id, "/ping", _text, _chat_type) do
    Pincer.Channels.Telegram.send_message(chat_id, "Pong! 🏓")
  end

  defp handle_command(chat_id, "/menu", _text, _chat_type) do
    Pincer.Channels.Telegram.send_message(chat_id, PincerPorts.UX.help_text(:telegram),
      reply_markup: Pincer.Channels.Telegram.menu_reply_markup()
    )
  end

  defp handle_command(chat_id, "/help", text, chat_type) do
    handle_command(chat_id, "/menu", text, chat_type)
  end

  defp handle_command(chat_id, "/commands", text, chat_type) do
    handle_command(chat_id, "/menu", text, chat_type)
  end

  defp handle_command(chat_id, "/models", _text, _chat_type) do
    providers = PincerPorts.LLM.list_providers()
    buttons = build_provider_buttons(providers)

    if buttons == [] do
      interaction_unavailable(chat_id)
    else
      Pincer.Channels.Telegram.send_message(chat_id, "🔧 <b>Selecione o Provider:</b>",
        reply_markup: %Telegex.Type.InlineKeyboardMarkup{inline_keyboard: buttons}
      )
    end
  end

  defp handle_command(chat_id, "/kanban", _text, chat_type) do
    session_id = session_context_for_chat(chat_id, chat_type).session_id
    Pincer.Channels.Telegram.send_message(chat_id, PincerPorts.Project.kanban(session_id))
  end

  defp handle_command(chat_id, "/project", text, chat_type) do
    context = session_context_for_chat(chat_id, chat_type)
    session_id = context.session_id
    response = PincerPorts.Project.project(session_id, text)
    send_project_message(chat_id, session_id, response)
    maybe_start_project_execution(chat_id, context)
  end

  defp handle_command(chat_id, "/pair", text, chat_type) do
    old_session_id = session_context_for_chat(chat_id, "private").session_id

    response =
      case Pairing.approve(:telegram, chat_id, text,
             is_dm: normalize_chat_type(chat_type) == "private",
             include_bound_agent: true,
             format_bound_agent: &"Esta DM agora aponta para o agente <code>#{&1}</code>.",
             on_approved: fn -> PincerPorts.Session.stop_session(old_session_id) end
           ) do
        {:ok, message} -> message
        {:error, _reason, message} -> message
      end

    Pincer.Channels.Telegram.send_message(chat_id, response)
  end

  defp handle_command(chat_id, "/status", _text, chat_type) do
    context = session_context_for_chat(chat_id, chat_type)
    session_id = context.session_id
    ensure_session_started(context)

    case PincerPorts.Project.handle_command(:status, nil, session_id) do
      {:ok, msg} -> Pincer.Channels.Telegram.send_message(chat_id, msg)
      {:error, reason} -> Pincer.Channels.Telegram.send_message(chat_id, "❌ #{reason}")
    end
  end

  defp handle_command(chat_id, "/new", _text, chat_type) do
    context = session_context_for_chat(chat_id, chat_type)
    session_id = context.session_id
    ensure_session_started(context)

    case PincerPorts.Session.reset(session_id) do
      :ok ->
        Pincer.Channels.Telegram.send_message(chat_id, "🔄 Session reset.")

      _ ->
        Pincer.Channels.Telegram.send_message(chat_id, "❌ Could not reset the session.")
    end
  end

  defp handle_command(chat_id, "/reset", text, chat_type),
    do: handle_command(chat_id, "/new", text, chat_type)

  defp handle_command(chat_id, "/model", text, chat_type) do
    context = session_context_for_chat(chat_id, chat_type)
    session_id = context.session_id
    ensure_session_started(context)

    case String.split(String.trim(text), "/", parts: 2) do
      [provider, model] when provider != "" and model != "" ->
        PincerPorts.Session.set_model(session_id, provider, model)

        Pincer.Channels.Telegram.send_message(
          chat_id,
          "✅ Modelo: <code>#{provider}/#{model}</code>"
        )

      _ ->
        Pincer.Channels.Telegram.send_message(
          chat_id,
          "Uso: /model <provider/modelo>\nEx: /model openrouter/mistral-7b"
        )
    end
  end

  defp handle_command(chat_id, "/think", text, chat_type) do
    context = session_context_for_chat(chat_id, chat_type)
    session_id = context.session_id
    ensure_session_started(context)
    level = text |> String.trim() |> String.downcase()
    valid = ["off", "low", "medium", "high"]

    new_level =
      if level in valid do
        level
      else
        # Toggle: cycle through levels
        {:ok, status} = PincerPorts.Session.get_status(session_id)
        current = status[:thinking_level] || "off"
        cycle_thinking(current)
      end

    PincerPorts.Session.set_thinking(session_id, new_level)
    Pincer.Channels.Telegram.send_message(chat_id, "🧠 Thinking: <code>#{new_level}</code>")
  end

  defp handle_command(chat_id, "/reasoning", text, chat_type) do
    context = session_context_for_chat(chat_id, chat_type)
    session_id = context.session_id
    ensure_session_started(context)

    arg = String.trim(text) |> String.downcase()

    new_visible =
      case arg do
        "on" ->
          true

        "off" ->
          false

        _ ->
          # Toggle based on current state
          {:ok, status} = PincerPorts.Session.get_status(session_id)
          not (status[:reasoning_visible] || false)
      end

    PincerPorts.Session.set_reasoning_visible(session_id, new_visible)

    msg = if new_visible, do: "👁 Reasoning: visible", else: "🙈 Reasoning: oculto"
    Pincer.Channels.Telegram.send_message(chat_id, msg)
  end

  defp handle_command(chat_id, "/verbose", text, chat_type) do
    context = session_context_for_chat(chat_id, chat_type)
    session_id = context.session_id
    ensure_session_started(context)

    case String.trim(text) |> String.downcase() do
      "on" ->
        PincerPorts.Session.set_verbose(session_id, true)
        Pincer.Channels.Telegram.send_message(chat_id, "🔊 Verbose: on")

      "off" ->
        PincerPorts.Session.set_verbose(session_id, false)
        Pincer.Channels.Telegram.send_message(chat_id, "🔇 Verbose: off")

      _ ->
        Pincer.Channels.Telegram.send_message(chat_id, "Uso: /verbose on|off")
    end
  end

  defp handle_command(chat_id, "/usage", text, chat_type) do
    context = session_context_for_chat(chat_id, chat_type)
    session_id = context.session_id
    ensure_session_started(context)
    display = text |> String.trim() |> String.downcase()
    valid = ["off", "tokens", "full"]

    if display in valid do
      PincerPorts.Session.set_usage(session_id, display)
      Pincer.Channels.Telegram.send_message(chat_id, "📊 Usage display: <code>#{display}</code>")
    else
      Pincer.Channels.Telegram.send_message(chat_id, "Uso: /usage off|tokens|full")
    end
  end

  defp handle_command(chat_id, cmd, _text, _chat_type) do
    Pincer.Channels.Telegram.send_message(
      chat_id,
      "❓ Unknown command: <code>#{cmd}</code>\n#{PincerPorts.UX.unknown_command_hint()}",
      reply_markup: Pincer.Channels.Telegram.menu_reply_markup()
    )
  end

  @doc false
  defp handle_callback(chat_id, chat_type, payload, message_id) do
    context = session_context_for_chat(chat_id, chat_type)
    session_id = context.session_id
    ensure_session_started(context)

    case PincerPorts.ChannelPolicy.parse(:telegram, payload) do
      {:ok, {:page, provider_id, page}} ->
        models = PincerPorts.LLM.list_models(provider_id)
        current_model = current_model_for_session(session_id)

        buttons =
          PincerPorts.UX.build_keyboard(
            :telegram,
            provider_id,
            models,
            page,
            current_model
          )

        if buttons == [] do
          interaction_unavailable(chat_id)
        else
          edit_callback_message(
            chat_id,
            message_id,
            "🤖 <b>Models from #{provider_id} (page #{page}):</b>",
            reply_markup: %Telegex.Type.InlineKeyboardMarkup{inline_keyboard: buttons},
            parse_mode: "HTML"
          )
        end

      {:ok, {:select_provider, provider_id}} ->
        models = PincerPorts.LLM.list_models(provider_id)
        current_model = current_model_for_session(session_id)

        buttons =
          PincerPorts.UX.build_keyboard(
            :telegram,
            provider_id,
            models,
            1,
            current_model
          )

        if buttons == [] do
          interaction_unavailable(chat_id)
        else
          edit_callback_message(
            chat_id,
            message_id,
            "🤖 <b>Selecione o Modelo para #{provider_id}:</b>",
            reply_markup: %Telegex.Type.InlineKeyboardMarkup{inline_keyboard: buttons},
            parse_mode: "HTML"
          )
        end

      {:ok, {:select_model, provider_id, model}} ->
        ensure_session_started(context)

        PincerPorts.Session.set_model(session_id, provider_id, model)

        edit_callback_message(
          chat_id,
          message_id,
          "✅ <b>Model configured!</b>\nSession: <code>#{session_id}</code>\nProvider: <code>#{provider_id}</code>\nModel: <code>#{model}</code>",
          parse_mode: "HTML"
        )

      {:ok, :back_to_providers} ->
        providers = PincerPorts.LLM.list_providers()
        buttons = build_provider_buttons(providers)

        if buttons == [] do
          interaction_unavailable(chat_id)
        else
          edit_callback_message(
            chat_id,
            message_id,
            "🔧 <b>Selecione o Provider:</b>",
            reply_markup: %Telegex.Type.InlineKeyboardMarkup{inline_keyboard: buttons},
            parse_mode: "HTML"
          )
        end

      {:ok, :show_menu} ->
        handle_command(chat_id, "/menu", "", chat_type)

      {:ok, {:approval, decision}} ->
        context = session_context_for_chat(chat_id, chat_type)
        session_id = context.session_id
        ensure_session_started(context)

        case decision do
          :approved ->
            PincerPorts.Session.process_input(session_id, "aprovo")
            edit_callback_message(chat_id, message_id, "✅ Aprovado", parse_mode: "HTML")

          :rejected ->
            PincerPorts.Session.process_input(session_id, "rejeito")
            edit_callback_message(chat_id, message_id, "❌ Rejeitado", parse_mode: "HTML")

          :approve_all ->
            PincerPorts.Session.approve_all(session_id, 600)

            edit_callback_message(chat_id, message_id, "🔓 Auto-aprovação ativa por 10 minutos",
              parse_mode: "HTML"
            )
        end

      {:error, reason} ->
        Logger.warning("[TELEGRAM] Invalid callback payload: #{inspect(reason)}")
        callback_invalid(chat_id)
    end
  end

  defp edit_callback_message(chat_id, message_id, text, opts) do
    case Pincer.Channels.Telegram.api_client().edit_message_text(chat_id, message_id, text, opts) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = error ->
        Logger.warning("[TELEGRAM] Callback message edit failed: #{inspect(reason)}")

        Pincer.Channels.Telegram.send_message(
          chat_id,
          "Nao consegui atualizar o menu agora. Use /menu para continuar.",
          reply_markup: Pincer.Channels.Telegram.menu_reply_markup()
        )

        error
    end
  end

  defp callback_invalid(chat_id) do
    Pincer.Channels.Telegram.send_message(
      chat_id,
      "Opcao de menu desconhecida ou expirada. Use /menu para abrir novamente.",
      reply_markup: Pincer.Channels.Telegram.menu_reply_markup()
    )
  end

  defp interaction_unavailable(chat_id) do
    Pincer.Channels.Telegram.send_message(
      chat_id,
      "Nao consegui montar o menu interativo agora. Use /menu para continuar.",
      reply_markup: Pincer.Channels.Telegram.menu_reply_markup()
    )
  end

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_, _), do: nil

  defp authorize_private_dm(chat_id, chat_type) do
    policy_config = Application.get_env(:pincer, :telegram_channel_config, %{})
    Pairing.authorize_dm(:telegram, chat_id, policy_config, is_dm: chat_type == "private")
  end

  defp normalize_chat_type(nil), do: ""

  defp normalize_chat_type(chat_type),
    do: chat_type |> to_string() |> String.trim() |> String.downcase()

  defp cycle_thinking("off"), do: "low"
  defp cycle_thinking("low"), do: "medium"
  defp cycle_thinking("medium"), do: "high"
  defp cycle_thinking(_), do: "off"

  defp session_context_for_chat(chat_id, chat_type) do
    channel_config = Application.get_env(:pincer, :telegram_channel_config, %{})

    PincerPorts.Session.resolve(
      :telegram,
      %{chat_id: chat_id, chat_type: chat_type},
      channel_config
    )
  end

  defp ensure_session_started(%PincerPorts.Session.Context{} = context) do
    Pincer.Channels.Shared.SessionBridge.ensure_started(context,
      on_start: fn sid ->
        Logger.info(
          "[TELEGRAM] Creating new session: #{sid} (root_agent=#{context.root_agent_id})"
        )
      end
    )
  end

  defp maybe_start_project_execution(chat_id, %PincerPorts.Session.Context{} = context) do
    Pincer.Channels.Shared.ProjectBridge.kickoff(context.session_id,
      ensure_session: fn -> ensure_session_started(context) end,
      ensure_worker: fn ->
        Pincer.Channels.Telegram.Session.ensure_started(chat_id, context.session_id)
      end,
      send_message: fn text -> Pincer.Channels.Telegram.send_message(chat_id, text) end,
      log_tag: "TELEGRAM"
    )
  end

  defp send_project_message(chat_id, session_id, response) do
    case project_reply_markup(session_id) do
      nil ->
        Pincer.Channels.Telegram.send_message(chat_id, response)

      reply_markup ->
        Pincer.Channels.Telegram.send_message(chat_id, response, reply_markup: reply_markup)
    end
  end

  defp project_reply_markup(session_id) do
    case PincerPorts.Project.phase(session_id) do
      :await_kind ->
        %{
          keyboard: [[%{text: "software"}, %{text: "nao-software"}]],
          resize_keyboard: true,
          one_time_keyboard: true
        }

      _ ->
        nil
    end
  end

  defp build_provider_buttons(providers) do
    providers
    |> Enum.reduce([], fn provider, acc ->
      case PincerPorts.ChannelPolicy.provider_selector_id(:telegram, provider.id) do
        {:ok, callback_data} ->
          [[%{text: provider.name, callback_data: callback_data}] | acc]

        {:error, :payload_too_large} ->
          Logger.warning(
            "[TELEGRAM] Skipping provider button with oversized callback payload: #{inspect(provider.id)}"
          )

          acc

        {:error, _reason} ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp current_model_for_session(session_id) do
    case PincerPorts.Session.get_status(session_id) do
      {:ok, %{model_override: %{model: model}}} -> model
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
