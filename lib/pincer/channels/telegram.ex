defmodule Pincer.Channels.Telegram do
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

  Session IDs are resolved by `Pincer.Core.SessionScopePolicy`.
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
  2. Incoming messages are routed to `Pincer.Session.Server.process_input/2`
  3. Responses are sent back via `Telegex.send_message/2`

  ## Examples

      # Send a message to a Telegram chat
      Pincer.Channels.Telegram.send_message("123456789", "Hello from Pincer!")

      # Start the channel (normally done by Supervisor)
      Pincer.Channels.Telegram.start_link(%{"token_env" => "TELEGRAM_BOT_TOKEN"})

  ## See Also

  - `Pincer.Channels.Telegram.UpdatesProvider` - The polling GenServer
  - `Pincer.Session.Server` - Session message processing
  - `Pincer.LLM.Client` - Model selection integration
  """

  use Supervisor
  @behaviour Pincer.Channel
  require Logger
  alias Pincer.Core.UX
  alias Pincer.Core.UX.MenuPolicy

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
  @impl Pincer.Channel
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

      children = if Mix.env() == :test, do: [], else: [Pincer.Channels.Telegram.UpdatesProvider]

      Supervisor.init(children, strategy: :one_for_one)
    else
      Logger.warning("Telegram token not found. Channel ignored.")
      :ignore
    end
  end

  @doc """
  Sends a text message to a Telegram chat.

  This is the implementation of `Pincer.Channel.send_message/2` callback.
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
  @impl Pincer.Channel
  def send_message(chat_id, text, opts \\ []) do
    # 1. Pipeline: Strip Reasoning -> Convert Markdown to HTML
    html_text =
      text
      |> strip_reasoning()
      |> markdown_to_html()

    do_send_message(chat_id, html_text, Keyword.put(opts, :parse_mode, "HTML"))
  end

  @doc """
  Updates an existing Telegram message.
  """
  @impl Pincer.Channel
  def update_message(chat_id, message_id, text) do
    html_text =
      text
      |> strip_reasoning()
      |> markdown_to_html()

    case Pincer.Channels.Telegram.api_client().edit_message_text(chat_id, message_id, html_text,
           parse_mode: "HTML"
         ) do
      {:ok, _} -> :ok
      {:error, %Telegex.Error{description: "Bad Request: message is not modified"}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_send_message(chat_id, text, opts) do
    case Pincer.Channels.Telegram.api_client().send_message(chat_id, text, opts) do
      {:ok, %{message_id: mid}} ->
        {:ok, mid}

      {:error, %Telegex.Error{description: desc}}
      when desc in ["Bad Request: message is too long", "Bad Request: text is too long"] ->
        Logger.warning("Telegram message too long. Splitting into chunks...")

        # Split into ~4000 char chunks to stay well under the 4096 limit
        # We perform splitting on the raw text for simplicity
        chunks =
          text
          |> String.codepoints()
          |> Enum.chunk_every(4000)
          |> Enum.map(&Enum.join/1)

        # We return the first chunk's ID to keep the streaming flow if needed
        # though splitting usually happens at the end.
        [first | rest] = chunks

        {:ok, %{message_id: mid}} =
          Pincer.Channels.Telegram.api_client().send_message(chat_id, first, opts)

        Enum.each(rest, fn chunk ->
          Process.sleep(100)
          Pincer.Channels.Telegram.api_client().send_message(chat_id, chunk, opts)
        end)

        {:ok, mid}

      {:error, %Telegex.Error{description: desc}} ->
        # ONLY attempt fallback if we are currently using a parse_mode (like HTML)
        if Keyword.has_key?(opts, :parse_mode) do
          Logger.warning(
            "Telegram HTML parsing failed. Falling back to plain text. Error: #{desc}"
          )

          plain_text =
            text
            |> String.replace("&lt;", "<")
            |> String.replace("&gt;", ">")
            |> String.replace("&amp;", "&")
            |> String.replace("&quot;", "\"")
            |> String.replace(~r/<[^>]+>/, "")

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

  # Removes thinking blocks common in reasoning models (DeepSeek, Gemini, etc.)
  defp strip_reasoning(text) do
    text
    |> String.replace(~r/<thought>.*?<\/thought>/is, "")
    |> String.replace(~r/<thinking>.*?<\/thinking>/is, "")
    |> String.replace(~r/^.*?think>\s*/is, "")
    |> String.trim()
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
  2. Uses Earmark to parse structural Markdown from the remaining text
  3. Renders the AST via Pincer.Channels.Telegram.Renderer
  4. Unfences the protected HTML for a 100% faithful hybrid output.
  """
  def markdown_to_html(text) do
    # 1. Pre-processing
    prepared =
      text
      |> strip_reasoning()
      |> String.replace("\r\n", "\n")

    # 2. Sequential Protection (Fencing) for Hybrid HTML Support
    # Order: Blocks (pre/code blocks) -> Inline Tags
    {fenced, map} = {prepared, %{}}

    # Phase A: Code Blocks and Pre blocks (Whole blocks)
    {fenced, map} =
      Regex.scan(~r/<(pre|code)(?:\s+[^>]*?)?>(.*?)<\/\1>/is, fenced)
      |> Enum.reduce({fenced, map}, fn [full, tag, content], {t, m} ->
        placeholder = "⦓B#{map_size(m)}⦔"
        content = "<#{tag}>#{content}</#{tag}>"
        {String.replace(t, full, placeholder), Map.put(m, placeholder, content)}
      end)

    # Phase B: Remaining safe inline tags
    safe_tags = ~w(b i u s strong em strike del a blockquote)

    {fenced, map} =
      Enum.reduce(safe_tags, {fenced, map}, fn tag, {acc_text, acc_map} ->
        # Opening tags
        {acc_text, acc_map} =
          Regex.scan(~r/<#{tag}(?:\s+[^>]*?)?>/i, acc_text)
          |> Enum.uniq()
          |> Enum.reduce({acc_text, acc_map}, fn [match], {t, m} ->
            placeholder = "⦓T#{map_size(m)}⦔"
            {String.replace(t, match, placeholder), Map.put(m, placeholder, match)}
          end)

        # Closing tags
        {acc_text, acc_map} =
          Regex.scan(~r/<\/#{tag}>/i, acc_text)
          |> Enum.uniq()
          |> Enum.reduce({acc_text, acc_map}, fn [match], {t, m} ->
            placeholder = "⦓T#{map_size(m)}⦔"
            {String.replace(t, match, placeholder), Map.put(m, placeholder, match)}
          end)

        {acc_text, acc_map}
      end)

    # 3. Main Parsing & Rendering (Professional AST approach)
    rendered =
      case Earmark.as_ast(fenced) do
        {:ok, ast, _warnings} ->
          Pincer.Channels.Telegram.Renderer.render(ast)

        {:error, ast, _errors} ->
          Pincer.Channels.Telegram.Renderer.render(ast)
      end

    # 4. Restoration (Unfencing)
    restored =
      Enum.reduce(map, rendered, fn {placeholder, content}, acc ->
        String.replace(acc, placeholder, content)
      end)

    String.trim(restored)
  end

  @doc false
  def register_commands do
    policy = MenuPolicy.registerable_commands(:telegram, UX.commands())

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
          keyboard: [[%{text: UX.menu_button_label()}]],
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
  `Pincer.Core.SessionScopePolicy`.

  ## Examples

  The UpdatesProvider is started automatically by the Telegram supervisor:

      # Started internally by Pincer.Channels.Telegram
      Pincer.Channels.Telegram.UpdatesProvider.start_link(nil)
  """

  use GenServer
  require Logger
  alias Pincer.Core.AccessPolicy
  alias Pincer.Core.ChannelInteractionPolicy
  alias Pincer.Core.Pairing
  alias Pincer.Core.ProjectBoard
  alias Pincer.Core.ProjectOrchestrator
  alias Pincer.Core.RetryPolicy
  alias Pincer.Core.SessionScopePolicy
  alias Pincer.Core.Telemetry, as: CoreTelemetry
  alias Pincer.Core.UX
  alias Pincer.Session.Server

  @base_poll_interval 1000
  @max_poll_interval 30_000
  @max_attachment_bytes 20_971_520
  @multimodal_extension_mime %{
    ".pdf" => "application/pdf",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".webp" => "image/webp",
    ".gif" => "image/gif",
    ".log" => "text/plain",
    ".txt" => "text/plain"
  }

  @doc false
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{offset: 0, failures: 0}, name: __MODULE__)
  end

  @impl GenServer
  def init(state) do
    if Mix.env() != :test do
      Logger.info("Telegram Poller Started (Manual Mode).")
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
  def handle_info(:poll, state) do
    {new_offset, failures} = fetch_updates(state.offset, state.failures)
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

  defp fetch_updates(offset, failures) do
    case Pincer.Channels.Telegram.api_client().get_updates(offset: offset, timeout: 5) do
      {:ok, updates} ->
        Enum.each(updates, &safe_process_update/1)

        new_offset =
          if Enum.empty?(updates) do
            offset
          else
            List.last(updates).update_id + 1
          end

        {new_offset, 0}

      {:error, reason} ->
        next_failures = failures + 1
        CoreTelemetry.emit_error(reason, %{component: :telegram_poller, failures: next_failures})
        interval_ms = next_poll_interval(next_failures)

        if RetryPolicy.transient?(reason) do
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
    chat = map_value(message, :chat)
    chat_id = map_value(chat, :id)
    chat_type = map_value(chat, :type)
    message_id = map_value(message, :message_id)

    if is_binary(data) and not is_nil(chat_id) and is_integer(message_id) do
      handle_callback(chat_id, chat_type, data, message_id)
    else
      Logger.warning("[TELEGRAM] Ignoring malformed callback query: #{inspect(callback_query)}")
    end
  end

  defp process_update(%{message: message}) when is_map(message) do
    chat = map_value(message, :chat)
    chat_id = map_value(chat, :id)
    chat_type = map_value(chat, :type)
    text = map_value(message, :text)
    trimmed = if is_binary(text), do: String.trim(text), else: ""
    has_attachments = has_supported_attachments?(message)

    cond do
      is_nil(chat_id) ->
        Logger.debug("Ignoring malformed Telegram message without chat_id: #{inspect(message)}")

      is_binary(text) and not has_attachments and String.starts_with?(trimmed, "/") ->
        [cmd | rest] = String.split(trimmed, " ")
        handle_command(chat_id, cmd, Enum.join(rest, " "), chat_type)

      is_binary(text) and not has_attachments ->
        case UX.resolve_shortcut(trimmed) do
          {:ok, command} ->
            handle_command(chat_id, command, "", chat_type)

          :error ->
            if maybe_handle_project_message(chat_id, chat_type, text) do
              :ok
            else
              do_process_message(chat_id, text, chat_type)
            end
        end

      has_attachments ->
        case prepare_input_content(message) do
          {:ok, input_content} ->
            do_process_message(chat_id, input_content, chat_type)

          :empty ->
            Logger.debug("[TELEGRAM] Ignoring message without text/supportable attachments.")
        end

      true ->
        Logger.debug("Ignoring unsupported Telegram message payload: #{inspect(message)}")
    end
  end

  defp process_update(update) do
    Logger.debug("Ignoring unsupported update or update without text: #{inspect(update)}")
  end

  defp do_process_message(chat_id, input_content, chat_type) do
    case authorize_private_dm(chat_id, chat_type) do
      :allow ->
        session_id = session_id_for_chat(chat_id, chat_type)
        Logger.info("[TELEGRAM] Message received from #{chat_id}")

        ensure_session_started(session_id)
        Pincer.Channels.Telegram.Session.ensure_started(chat_id, session_id)

        Logger.info("[TELEGRAM] Routing message to Session ID: #{session_id}")

        case Server.process_input(session_id, input_content) do
          {:ok, :started} ->
            :ok

          {:ok, :butler_notified} ->
            :ok

          {:ok, :queued} ->
            :ok

          {:ok, response} ->
            Logger.info("[TELEGRAM] Got immediate response, sending back to chat_id: #{chat_id}")
            Pincer.Channels.Telegram.send_message(chat_id, response)

          _ ->
            :ok
        end

      {:deny, message} ->
        Pincer.Channels.Telegram.send_message(chat_id, message,
          reply_markup: Pincer.Channels.Telegram.menu_reply_markup()
        )
    end
  end

  @doc false
  @spec prepare_input_content(map(), module()) :: {:ok, String.t() | [map()]} | :empty
  def prepare_input_content(message, api_client \\ Pincer.Channels.Telegram.api_client())

  def prepare_input_content(message, api_client) when is_map(message) do
    base_text =
      message
      |> map_value(:caption)
      |> normalize_text()

    {attachment_text, refs} = extract_attachment_parts(message, api_client)
    text_content = [base_text, attachment_text] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")

    cond do
      refs == [] and text_content == "" ->
        :empty

      refs == [] ->
        {:ok, text_content}

      true ->
        text_parts =
          if text_content == "" do
            []
          else
            [%{"type" => "text", "text" => text_content}]
          end

        {:ok, text_parts ++ refs}
    end
  end

  def prepare_input_content(_message, _api_client), do: :empty

  defp has_supported_attachments?(message) when is_map(message) do
    has_document?(message) or has_photo?(message)
  end

  defp has_supported_attachments?(_), do: false

  defp has_document?(message), do: is_map(map_value(message, :document))

  defp has_photo?(message) do
    case map_value(message, :photo) do
      photos when is_list(photos) -> photos != []
      _ -> false
    end
  end

  defp extract_attachment_parts(message, api_client) do
    {text_acc, refs_acc} =
      {"", []}
      |> maybe_collect_document(message, api_client)
      |> maybe_collect_photo(message, api_client)

    {String.trim(text_acc), refs_acc}
  end

  defp maybe_collect_document({text_acc, refs_acc}, message, api_client) do
    case map_value(message, :document) do
      document when is_map(document) ->
        filename = sanitize_filename(map_value(document, :file_name) || "document")
        size = normalize_size(map_value(document, :file_size))
        mime = normalize_mime(document, filename)
        ext = filename |> Path.extname() |> String.downcase()

        cond do
          size > @max_attachment_bytes ->
            text = append_text_meta(text_acc, filename, size, " (arquivo grande demais)")
            {text, refs_acc}

          not multimodal_extension?(ext, mime) ->
            text = append_text_meta(text_acc, filename, size, " (formato nao suportado)")
            {text, refs_acc}

          true ->
            case build_attachment_ref(document, filename, size, mime, api_client) do
              {:ok, ref} ->
                {text_acc, refs_acc ++ [ref]}

              {:error, reason} ->
                Logger.warning(
                  "[TELEGRAM] Failed to resolve document attachment '#{filename}': #{inspect(reason)}"
                )

                text = append_text_meta(text_acc, filename, size, " (erro ao resolver arquivo)")
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
        case largest_photo(photos) do
          nil ->
            {text_acc, refs_acc}

          photo ->
            size = normalize_size(map_value(photo, :file_size))
            unique_id = map_value(photo, :file_unique_id) || map_value(photo, :file_id) || "photo"
            filename = sanitize_filename("photo_#{unique_id}.jpg")

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

  defp build_attachment_ref(file_obj, filename, size, mime, api_client) do
    with file_id when is_binary(file_id) <- normalize_binary(map_value(file_obj, :file_id)),
         {:ok, file_path} <- resolve_file_path(api_client, file_id) do
      {:ok,
       %{
         "type" => "attachment_ref",
         "url" => "telegram://file/#{file_path}",
         "mime_type" => mime,
         "filename" => filename,
         "size" => size
       }}
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

  defp multimodal_extension?(ext, mime) do
    Map.has_key?(@multimodal_extension_mime, ext) or String.starts_with?(mime, "text/")
  end

  defp normalize_mime(document, filename) do
    ext = filename |> Path.extname() |> String.downcase()
    declared = normalize_binary(map_value(document, :mime_type))

    cond do
      is_binary(declared) and declared != "" ->
        declared

      Map.has_key?(@multimodal_extension_mime, ext) ->
        @multimodal_extension_mime[ext]

      true ->
        "application/octet-stream"
    end
  end

  defp normalize_size(value) when is_integer(value) and value >= 0, do: value

  defp normalize_size(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> 0
    end
  end

  defp normalize_size(_), do: 0

  defp append_text_meta(text_acc, filename, size, suffix) do
    meta = "[Attachment: #{filename} (#{size} bytes)]#{suffix}"

    [text_acc, meta]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp largest_photo(photos) do
    photos
    |> Enum.filter(&is_map/1)
    |> Enum.max_by(
      fn photo -> normalize_size(map_value(photo, :file_size)) end,
      fn -> nil end
    )
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

  defp normalize_binary(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_binary()

  defp normalize_binary(value) when is_integer(value),
    do: value |> Integer.to_string() |> normalize_binary()

  defp normalize_binary(_), do: nil

  defp sanitize_filename(filename) do
    String.replace(filename, ~r/[<>&"'\x00-\x1F]/, "_")
  end

  @doc false
  defp handle_command(chat_id, "/ping", _text, _chat_type) do
    Pincer.Channels.Telegram.send_message(chat_id, "Pong! 🏓")
  end

  defp handle_command(chat_id, "/menu", _text, _chat_type) do
    Pincer.Channels.Telegram.send_message(chat_id, UX.help_text(:telegram),
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
    providers = Pincer.LLM.Client.list_providers()
    buttons = build_provider_buttons(providers)

    if buttons == [] do
      interaction_unavailable(chat_id)
    else
      Pincer.Channels.Telegram.send_message(chat_id, "🔧 <b>Select AI Provider:</b>",
        reply_markup: %Telegex.Type.InlineKeyboardMarkup{inline_keyboard: buttons}
      )
    end
  end

  defp handle_command(chat_id, "/kanban", _text, chat_type) do
    session_id = session_id_for_chat(chat_id, chat_type)

    board =
      case ProjectOrchestrator.board(session_id) do
        {:ok, session_board} -> session_board
        :not_found -> ProjectBoard.render()
      end

    Pincer.Channels.Telegram.send_message(chat_id, board)
  end

  defp handle_command(chat_id, "/project", text, chat_type) do
    session_id = session_id_for_chat(chat_id, chat_type)
    response = ProjectOrchestrator.start(session_id, text)
    Pincer.Channels.Telegram.send_message(chat_id, response)
  end

  defp handle_command(chat_id, "/pair", text, chat_type) do
    if normalize_chat_type(chat_type) == "private" do
      handle_pairing_command(chat_id, text)
    else
      Pincer.Channels.Telegram.send_message(
        chat_id,
        "Pairing so pode ser concluido em DM privada."
      )
    end
  end

  defp handle_command(chat_id, "/status", _text, chat_type) do
    session_id = session_id_for_chat(chat_id, chat_type)
    ensure_session_started(session_id)

    case Server.get_status(session_id) do
      {:ok, state} ->
        provider = if state.model_override, do: state.model_override.provider, else: "Default"
        model = if state.model_override, do: state.model_override.model, else: "Default"
        status = if state.status == :working, do: "🏗️ Busy", else: "😴 Idle"

        msg = """
        📊 <b>Session Status</b>
        ━━━━━━━━━━━━━━━
        🆔 <b>ID</b>: <code>#{session_id}</code>
        📡 <b>Status</b>: #{status}
        🏢 <b>Provider</b>: <code>#{provider}</code>
        🤖 <b>Model</b>: <code>#{model}</code>
        📜 <b>History</b>: #{length(state.history)} messages
        """

        Pincer.Channels.Telegram.send_message(chat_id, msg)

      _ ->
        Pincer.Channels.Telegram.send_message(chat_id, "❌ Could not get session status.")
    end
  end

  defp handle_command(chat_id, cmd, _text, _chat_type) do
    Pincer.Channels.Telegram.send_message(
      chat_id,
      "❓ Unknown command: <code>#{cmd}</code>\n#{UX.unknown_command_hint()}",
      reply_markup: Pincer.Channels.Telegram.menu_reply_markup()
    )
  end

  @doc false
  defp handle_callback(chat_id, chat_type, payload, message_id) do
    case ChannelInteractionPolicy.parse(:telegram, payload) do
      {:ok, {:select_provider, provider_id}} ->
        models = Pincer.LLM.Client.list_models(provider_id)

        buttons =
          build_model_buttons(provider_id, models)
          |> with_back_to_providers_button()

        if buttons == [] do
          interaction_unavailable(chat_id)
        else
          edit_callback_message(
            chat_id,
            message_id,
            "🤖 **Select Model for #{provider_id}:**",
            reply_markup: %Telegex.Type.InlineKeyboardMarkup{inline_keyboard: buttons}
          )
        end

      {:ok, {:select_model, provider_id, model}} ->
        session_id = session_id_for_chat(chat_id, chat_type)

        ensure_session_started(session_id)

        Server.set_model(session_id, provider_id, model)

        edit_callback_message(
          chat_id,
          message_id,
          "✅ **Model configured!**\nSession: `#{session_id}`\nProvider: `#{provider_id}`\nModel: `#{model}`",
          []
        )

      {:ok, :back_to_providers} ->
        providers = Pincer.LLM.Client.list_providers()
        buttons = build_provider_buttons(providers)

        if buttons == [] do
          interaction_unavailable(chat_id)
        else
          edit_callback_message(
            chat_id,
            message_id,
            "🔧 **Select AI Provider:**",
            reply_markup: %Telegex.Type.InlineKeyboardMarkup{inline_keyboard: buttons}
          )
        end

      {:ok, :show_menu} ->
        handle_command(chat_id, "/menu", "", chat_type)

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

  defp handle_pairing_command(chat_id, text) do
    case String.trim(text || "") do
      "" ->
        Pincer.Channels.Telegram.send_message(
          chat_id,
          "Uso: /pair <codigo>. Solicite o codigo de pairing ao operador."
        )

      code ->
        case Pairing.approve_code(:telegram, chat_id, code) do
          :ok ->
            Pincer.Channels.Telegram.send_message(
              chat_id,
              "Pairing concluido com sucesso. Agora sua DM esta autorizada."
            )

          {:error, :not_pending} ->
            Pincer.Channels.Telegram.send_message(
              chat_id,
              "Nenhum pairing pendente para este usuario. Solicite um novo codigo ao operador."
            )

          {:error, :expired} ->
            Pincer.Channels.Telegram.send_message(
              chat_id,
              "Codigo de pairing expirado. Solicite um novo codigo ao operador."
            )

          {:error, :invalid_code} ->
            Pincer.Channels.Telegram.send_message(
              chat_id,
              "Codigo de pairing invalido. Revise o codigo e tente novamente."
            )

          {:error, :attempts_exceeded} ->
            Pincer.Channels.Telegram.send_message(
              chat_id,
              "Tentativas excedidas para este codigo. Solicite um novo codigo ao operador."
            )
        end
    end
  end

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_, _), do: nil

  defp authorize_private_dm(chat_id, "private") do
    policy_config = Application.get_env(:pincer, :telegram_channel_config, %{})

    case AccessPolicy.authorize_dm(:telegram, chat_id, policy_config) do
      {:allow, _meta} -> :allow
      {:deny, %{user_message: message}} -> {:deny, message}
    end
  end

  defp authorize_private_dm(_chat_id, _chat_type), do: :allow

  defp normalize_chat_type(nil), do: ""

  defp normalize_chat_type(chat_type),
    do: chat_type |> to_string() |> String.trim() |> String.downcase()

  defp maybe_handle_project_message(chat_id, chat_type, text) do
    session_id = session_id_for_chat(chat_id, chat_type)

    case ProjectOrchestrator.continue(session_id, text) do
      {:handled, response} ->
        Pincer.Channels.Telegram.send_message(chat_id, response)
        true

      :not_active ->
        false
    end
  end

  defp session_id_for_chat(chat_id, chat_type) do
    channel_config = Application.get_env(:pincer, :telegram_channel_config, %{})

    SessionScopePolicy.resolve(
      :telegram,
      %{chat_id: chat_id, chat_type: chat_type},
      channel_config
    )
  end

  defp ensure_session_started(session_id) do
    case Registry.lookup(Pincer.Session.Registry, session_id) do
      [] ->
        Logger.info("[TELEGRAM] Creating new session: #{session_id}")
        Pincer.Session.Supervisor.start_session(session_id)

      [_] ->
        :ok
    end
  end

  defp build_provider_buttons(providers) do
    Enum.reduce(providers, [], fn provider, acc ->
      case ChannelInteractionPolicy.provider_selector_id(:telegram, provider.id) do
        {:ok, callback_data} ->
          acc ++ [[%{text: provider.name, callback_data: callback_data}]]

        {:error, :payload_too_large} ->
          Logger.warning(
            "[TELEGRAM] Skipping provider button with oversized callback payload: #{inspect(provider.id)}"
          )

          acc

        {:error, _reason} ->
          acc
      end
    end)
  end

  defp build_model_buttons(provider_id, models) do
    Enum.reduce(models, [], fn model, acc ->
      case ChannelInteractionPolicy.model_selector_id(:telegram, provider_id, model) do
        {:ok, callback_data} ->
          acc ++ [[%{text: model, callback_data: callback_data}]]

        {:error, :payload_too_large} ->
          Logger.warning(
            "[TELEGRAM] Skipping model button with oversized callback payload: #{inspect(model)}"
          )

          acc

        {:error, _reason} ->
          acc
      end
    end)
  end

  defp with_back_to_providers_button(buttons) do
    case ChannelInteractionPolicy.back_to_providers_id(:telegram) do
      {:ok, callback_data} ->
        buttons ++ [[%{text: "⬅️ Back", callback_data: callback_data}]]

      {:error, _reason} ->
        buttons
    end
  end
end
