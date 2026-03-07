defmodule Pincer.Channels.Discord do
  @moduledoc """
  Discord channel adapter using Nostrum.

  This module handles:
  - Receiving messages from Discord and routing to sessions
  - Sending messages from sessions back to Discord
  - Formatting Pincer Markdown to Discord-flavored Markdown
  """
  @behaviour Pincer.Ports.Channel
  use Supervisor
  require Logger
  alias Pincer.Core.Structs.IncomingMessage
  alias Pincer.Core.Session.Server
  alias Pincer.Core.UX
  alias Pincer.Core.UX.MenuPolicy

  @doc """
  Starts the Discord channel.
  Since we set nostrum to `runtime: false`, we must start it manually here.
  """
  @impl true
  def start_link(config) do
    # 1. Fetch token from environment
    token = System.get_env(config["token_env"] || "DISCORD_BOT_TOKEN")

    if token && token != "" do
      Application.put_env(:pincer, :discord_channel_config, config)

      # 2. Set token in Nostrum config before starting
      Application.put_env(:nostrum, :token, token)

      # 3. Start Nostrum application
      case Application.ensure_all_started(:nostrum) do
        {:ok, _} ->
          Logger.info("[DISCORD] Nostrum started successfully.")
          # 4. Start channel runtime under a dedicated supervisor
          Supervisor.start_link(__MODULE__, config, name: __MODULE__)

        {:error, reason} ->
          Logger.error("[DISCORD] Failed to start Nostrum: #{inspect(reason)}")
          :ignore
      end
    else
      Logger.warning("[DISCORD] Skipping Discord channel: No token found in environment.")
      :ignore
    end
  end

  @doc """
  Initializes the Discord channel.
  """
  @impl true
  def init(_config) do
    Logger.info("Discord Channel Adapter Initialized.")

    children = [
      {Pincer.Channels.Discord.Consumer, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Sends a message to a Discord channel.
  """
  @impl Pincer.Ports.Channel
  def send_message(channel_id, text, opts \\ []) do
    # 1. Handle auto-attachments (extract large code blocks)
    {text, files} = auto_attach_files(text, opts[:files] || [])

    # 2. Split text into manageable chunks
    formatted_text = markdown_to_discord(text)
    chunks = split_into_chunks(formatted_text, 1900)

    # 3. Transmit to Discord
    do_send_chunks(String.to_integer(channel_id), chunks, files, opts)
  end

  @doc """
  Updates an existing Discord message.
  """
  @impl Pincer.Ports.Channel
  def update_message(channel_id, message_id, text) do
    formatted_text = markdown_to_discord(text)
    # Note: Discord has a 2000 char limit for edits too.
    # For streaming, we assume the text stays within limits or it will fail.
    # Improving this with chunked edits is complex for streaming.
    case api_client().edit_message(String.to_integer(channel_id), message_id,
           content: formatted_text
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_send_chunks(channel_id, [first | rest], files, opts) do
    # Send first chunk with files and components
    nostrum_opts = [content: first]

    nostrum_opts =
      if opts[:components],
        do: nostrum_opts ++ [components: opts[:components]],
        else: nostrum_opts

    nostrum_opts = if Enum.any?(files), do: nostrum_opts ++ [files: files], else: nostrum_opts

    case api_client().create_message(channel_id, first, nostrum_opts) do
      {:ok, %{id: mid}} ->
        # Send remaining chunks as separate messages
        results =
          Enum.map(rest, fn chunk ->
            case api_client().create_message(channel_id, chunk, []) do
              {:ok, _} ->
                # Small delay to respect rate limits
                Process.sleep(200)
                :ok

              {:error, reason} ->
                Logger.error("[DISCORD] Failed to send subsequent chunk: #{inspect(reason)}")
                {:error, reason}
            end
          end)

        if Enum.all?(results, &(&1 == :ok)), do: {:ok, mid}, else: {:error, :partial_failure}

      {:error, reason} ->
        Logger.error("[DISCORD] Failed to send initial chunk: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_send_chunks(channel_id, [], files, opts) when files != [] do
    # No text, just files
    nostrum_opts = [content: ""]

    nostrum_opts =
      if opts[:components],
        do: nostrum_opts ++ [components: opts[:components]],
        else: nostrum_opts

    nostrum_opts = nostrum_opts ++ [files: files]

    case api_client().create_message(channel_id, "", nostrum_opts) do
      {:ok, %{id: mid}} -> {:ok, mid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_send_chunks(_, [], [], _), do: :ok

  def split_into_chunks("", _), do: []

  def split_into_chunks(text, max_len) do
    if String.length(text) <= max_len do
      [text]
    else
      # Try to split by double newline first, then newline, then space, then fallback
      do_split(text, max_len)
    end
  end

  defp do_split(text, max_len) do
    if String.length(text) <= max_len do
      [text]
    else
      chunk = String.slice(text, 0, max_len)

      # Use Unicode-aware reverse search for newline
      # String.split_at/2 or Regex might be more robust here
      last_nl = find_last_newline_within(chunk, 500) || max_len

      [String.slice(text, 0, last_nl) | do_split(String.slice(text, last_nl..-1//1), max_len)]
    end
  end

  defp find_last_newline_within(text, search_range) do
    len = String.length(text)
    start_pos = max(0, len - search_range)

    # We look for the last newline in the tail of the chunk
    tail = String.slice(text, start_pos..-1//1)

    case String.split(tail, "\n") do
      # No newline found in search_range
      [_] ->
        nil

      parts ->
        # The sum of lengths of all parts except the last one, plus the number of newlines
        last_part_len = parts |> List.last() |> String.length()
        len - last_part_len
    end
  end

  defp auto_attach_files(text, existing_files) do
    # If text contains a large code block, convert it to a file
    # We only do this if the block is significantly large to benefit from being a file
    if String.length(text) > 1500 and String.contains?(text, "```") do
      case Regex.run(~r/```(\w+)?\n([\s\S]*?)\n```/i, text) do
        [full_block, lang, code] when byte_size(code) > 1000 ->
          filename = "code_block.#{lang || "txt"}"
          file = %{name: filename, body: code}

          remaining_text =
            String.replace(text, full_block, "\n📎 *[Conteúdo enviado no anexo: #{filename}]*")

          auto_attach_files(remaining_text, existing_files ++ [file])

        _ ->
          {text, existing_files}
      end
    else
      {text, existing_files}
    end
  end

  @doc """
  Converts Pincer-standard Markdown to Discord-flavored Markdown.
  """
  def markdown_to_discord(text) do
    text
    |> strip_reasoning()
    |> String.trim()
  end

  defp strip_reasoning(text) do
    text
    # XML-style blocks
    |> String.replace(~r/<thought>.*?<\/thought>/is, "")
    |> String.replace(~r/<thinking>.*?<\/thinking>/is, "")
    # Prefix style: "think> ... \n\n" or just at the start
    |> String.replace(~r/^think>.*?(\n\n|\r\n\r\n|$)/is, "")
  end

  defmodule Consumer do
    @moduledoc """
    Consumes Discord events and routes messages to Pincer sessions.
    """
    use Nostrum.Consumer
    alias Pincer.Core.AccessPolicy
    alias Pincer.Core.ChannelInteractionPolicy
    alias Pincer.Core.Pairing
    alias Pincer.Core.ProjectRouter
    alias Pincer.Core.SessionResolver
    alias Pincer.Core.UX
    alias Pincer.Core.Session.Server

    @impl true
    def handle_event({:MESSAGE_CREATE, msg, _ws_state}) do
      # Ignore messages from bots
      unless msg.author.bot do
        text = msg.content || ""
        trimmed = String.trim(text)

        if dm_pair_command?(msg, trimmed) do
          handle_command(msg, trimmed)
        else
          case authorize_dm_if_needed(msg) do
            :allow ->
              if String.starts_with?(trimmed, "/") do
                handle_command(msg, trimmed)
              else
                case UX.resolve_shortcut(trimmed) do
                  {:ok, command} ->
                    handle_command(msg, command)

                  :error ->
                    session_context = resolve_session_context(msg)
                    session_id = session_context.session_id

                    case ProjectRouter.continue_if_collecting(session_id, trimmed,
                           has_attachments: not Enum.empty?(msg.attachments)
                         ) do
                      {:handled, response} ->
                        Pincer.Channels.Discord.send_message("#{msg.channel_id}", response)
                        maybe_start_project_execution(msg.channel_id, session_context)

                      :not_handled ->
                        Logger.info(
                          "[DISCORD] Message from #{msg.author.username} in #{msg.channel_id}"
                        )

                        {attachment_text, attachment_refs} = process_attachments(msg.attachments)
                        text_content = (trimmed <> "\n" <> attachment_text) |> String.trim()

                        # Build the message content:
                        # - plain string  when there are no multimodal attachments
                        # - list of parts when there are PDFs/images (lazy refs resolved by Executor)
                        full_content =
                          if Enum.empty?(attachment_refs) do
                            text_content
                          else
                            text_parts =
                              if text_content != "",
                                do: [%{"type" => "text", "text" => text_content}],
                                else: []

                            text_parts ++ attachment_refs
                          end

                        has_content =
                          case full_content do
                            s when is_binary(s) -> s != ""
                            list when is_list(list) -> list != []
                          end

                        if has_content do
                          ensure_brain_session_started(session_context)

                          Pincer.Channels.Discord.Session.ensure_started(
                            msg.channel_id,
                            session_id
                          )

                          # Create agnostic IncomingMessage
                          incoming =
                            case full_content do
                              text when is_binary(text) ->
                                IncomingMessage.new(session_id, text)

                              parts when is_list(parts) ->
                                # Split text from attachments
                                {text_parts, att_parts} =
                                  Enum.split_with(parts, fn p -> p["type"] == "text" end)

                                text = Enum.map_join(text_parts, "\n", & &1["text"])
                                atts = Enum.map(att_parts, & &1["attachment"])

                                IncomingMessage.new(session_id, text: text, attachments: atts)
                            end

                          Server.process_input(session_id, incoming)
                        else
                          Logger.debug(
                            "[DISCORD] Ignoring empty message without supported attachments."
                          )
                        end
                    end
                end
              end

            {:deny, message} ->
              Pincer.Channels.Discord.send_message("#{msg.channel_id}", message)
          end
        end
      end
    end

    @impl true
    def handle_event({:READY, _data, _ws_state}) do
      Logger.info("[DISCORD] Bot is ready. Registering Slash Commands...")
      Pincer.Channels.Discord.register_commands()
    end

    @impl true
    def handle_event({:INTERACTION_CREATE, interaction, _ws_state}) do
      case interaction.type do
        2 -> handle_slash_command(interaction)
        3 -> handle_interaction(interaction)
        _ -> :noop
      end
    end

    defp dm_pair_command?(msg, trimmed) do
      dm_event?(msg) and String.starts_with?(String.downcase(trimmed), "/pair")
    end

    defp authorize_dm_if_needed(msg) do
      if dm_event?(msg) do
        sender_id = read_sender_id(msg.author)
        policy_config = Application.get_env(:pincer, :discord_channel_config, %{})

        case AccessPolicy.authorize_dm(:discord, sender_id, policy_config) do
          {:allow, _meta} -> :allow
          {:deny, %{user_message: message}} -> {:deny, message}
        end
      else
        :allow
      end
    end

    defp dm_event?(msg), do: Map.get(msg, :guild_id) in [nil, ""]

    defp read_sender_id(author) when is_map(author) do
      Map.get(author, :id) || Map.get(author, "id") || Map.get(author, :username) ||
        Map.get(author, "username") || "unknown"
    end

    defp read_sender_id(_), do: "unknown"

    defp resolve_session_context(context) do
      policy_config = Application.get_env(:pincer, :discord_channel_config, %{})
      sender_id = resolve_sender_id(context)

      SessionResolver.resolve(
        :discord,
        %{
          channel_id: read_field(context, :channel_id),
          guild_id: read_field(context, :guild_id),
          sender_id: sender_id
        },
        policy_config
      )
    end

    defp resolve_session_id(context), do: resolve_session_context(context).session_id

    defp resolve_sender_id(context) do
      read_optional_sender_id(read_field(context, :author)) ||
        read_field(read_field(context, :user), :id) ||
        read_field(read_field(read_field(context, :member), :user), :id) ||
        "unknown"
    end

    defp read_optional_sender_id(nil), do: nil
    defp read_optional_sender_id(author), do: read_sender_id(author)

    defp read_field(map, key) when is_map(map) and is_atom(key) do
      Map.get(map, key) || Map.get(map, Atom.to_string(key))
    end

    defp read_field(_, _), do: nil

    defp handle_slash_command(interaction) do
      command_name = interaction.data.name

      case command_name do
        "ping" ->
          response = %{
            type: 4,
            data: %{content: "Pong! 🏓"}
          }

          send_interaction_response(interaction, response)

        "menu" ->
          handle_menu_command(interaction)

        "status" ->
          handle_status_command(interaction)

        "models" ->
          handle_models_command(interaction)

        "kanban" ->
          handle_kanban_command(interaction)

        "project" ->
          handle_project_command(interaction)

        _ ->
          response = %{
            type: 4,
            data: %{content: "❓ Unknown command: `#{command_name}`\n#{UX.unknown_command_hint()}"}
          }

          send_interaction_response(interaction, response)
      end
    end

    defp handle_command(msg, "/ping") do
      Pincer.Channels.Discord.send_message("#{msg.channel_id}", "Pong! 🏓")
    end

    defp handle_command(msg, "/menu") do
      Pincer.Channels.Discord.send_message("#{msg.channel_id}", UX.help_text(:discord))
    end

    defp handle_command(msg, "/status") do
      session_id = resolve_session_id(msg)
      content = build_status_content(session_id)
      Pincer.Channels.Discord.send_message("#{msg.channel_id}", content)
    end

    defp handle_command(msg, "/models") do
      providers = Pincer.Ports.LLM.list_providers()
      buttons = build_provider_buttons(providers)

      buttons =
        case ChannelInteractionPolicy.menu_id(:discord) do
          {:ok, id} ->
            buttons ++ [%{type: 2, style: 2, label: UX.menu_button_label(), custom_id: id}]

          _ ->
            buttons
        end

      components = chunk_buttons(buttons)

      Pincer.Channels.Discord.send_message("#{msg.channel_id}", "🔧 **Select AI Provider:**",
        components: components
      )
    end

    defp handle_command(msg, "/kanban") do
      session_id = resolve_session_id(msg)

      Pincer.Channels.Discord.send_message(
        "#{msg.channel_id}",
        ProjectRouter.kanban(session_id)
      )
    end

    defp handle_command(msg, "/project") do
      session_context = resolve_session_context(msg)
      session_id = session_context.session_id
      response = ProjectRouter.project(session_id)
      Pincer.Channels.Discord.send_message("#{msg.channel_id}", response)
      maybe_start_project_execution(msg.channel_id, session_context)
    end

    defp handle_command(msg, "/project " <> details) do
      session_context = resolve_session_context(msg)
      session_id = session_context.session_id
      response = ProjectRouter.project(session_id, details)
      Pincer.Channels.Discord.send_message("#{msg.channel_id}", response)
      maybe_start_project_execution(msg.channel_id, session_context)
    end

    defp handle_command(msg, "/pair") do
      Pincer.Channels.Discord.send_message(
        "#{msg.channel_id}",
        "Uso: /pair <codigo>. Solicite o codigo de pairing ao operador."
      )
    end

    defp handle_command(msg, "/pair " <> code_input) do
      sender_id = read_sender_id(msg.author)
      code = String.trim(code_input)

      case Pairing.approve_code(:discord, sender_id, code) do
        :ok ->
          Pincer.Channels.Discord.send_message(
            "#{msg.channel_id}",
            "Pairing concluido com sucesso. Agora sua DM esta autorizada."
          )

        {:error, :not_pending} ->
          Pincer.Channels.Discord.send_message(
            "#{msg.channel_id}",
            "Nenhum pairing pendente para este usuario. Solicite um novo codigo ao operador."
          )

        {:error, :expired} ->
          Pincer.Channels.Discord.send_message(
            "#{msg.channel_id}",
            "Codigo de pairing expirado. Solicite um novo codigo ao operador."
          )

        {:error, :invalid_code} ->
          Pincer.Channels.Discord.send_message(
            "#{msg.channel_id}",
            "Codigo de pairing invalido. Revise o codigo e tente novamente."
          )

        {:error, :attempts_exceeded} ->
          Pincer.Channels.Discord.send_message(
            "#{msg.channel_id}",
            "Tentativas excedidas para este codigo. Solicite um novo codigo ao operador."
          )
      end
    end

    defp handle_command(msg, "/new") do
      session_context = resolve_session_context(msg)
      session_id = session_context.session_id
      ensure_brain_session_started(session_context)

      case Pincer.Core.Session.Server.reset(session_id) do
        :ok ->
          Pincer.Channels.Discord.send_message("#{msg.channel_id}", "🔄 Sessão reiniciada.")

        _ ->
          Pincer.Channels.Discord.send_message(
            "#{msg.channel_id}",
            "❌ Não foi possível reiniciar a sessão."
          )
      end
    end

    defp handle_command(msg, "/reset"), do: handle_command(msg, "/new")

    defp handle_command(msg, "/model") do
      Pincer.Channels.Discord.send_message(
        "#{msg.channel_id}",
        "Uso: /model <provider/modelo>\nEx: /model openrouter/mistral-7b"
      )
    end

    defp handle_command(msg, "/model " <> text) do
      session_context = resolve_session_context(msg)
      session_id = session_context.session_id
      ensure_brain_session_started(session_context)

      case String.split(String.trim(text), "/", parts: 2) do
        [provider, model] when provider != "" and model != "" ->
          Pincer.Core.Session.Server.set_model(session_id, provider, model)

          Pincer.Channels.Discord.send_message(
            "#{msg.channel_id}",
            "✅ Modelo: `#{provider}/#{model}`"
          )

        _ ->
          Pincer.Channels.Discord.send_message(
            "#{msg.channel_id}",
            "Uso: /model <provider/modelo>\nEx: /model openrouter/mistral-7b"
          )
      end
    end

    defp handle_command(msg, "/think") do
      Pincer.Channels.Discord.send_message("#{msg.channel_id}", "Uso: /think off|low|medium|high")
    end

    defp handle_command(msg, "/think " <> text) do
      session_context = resolve_session_context(msg)
      session_id = session_context.session_id
      ensure_brain_session_started(session_context)
      level = text |> String.trim() |> String.downcase()
      valid = ["off", "low", "medium", "high"]

      if level in valid do
        Pincer.Core.Session.Server.set_thinking(session_id, level)
        Pincer.Channels.Discord.send_message("#{msg.channel_id}", "🧠 Thinking: `#{level}`")
      else
        Pincer.Channels.Discord.send_message(
          "#{msg.channel_id}",
          "Uso: /think off|low|medium|high"
        )
      end
    end

    defp handle_command(msg, "/reasoning") do
      Pincer.Channels.Discord.send_message("#{msg.channel_id}", "Uso: /reasoning on|off")
    end

    defp handle_command(msg, "/reasoning " <> text) do
      session_context = resolve_session_context(msg)
      session_id = session_context.session_id
      ensure_brain_session_started(session_context)

      case String.trim(text) |> String.downcase() do
        "on" ->
          Pincer.Core.Session.Server.set_reasoning_visible(session_id, true)
          Pincer.Channels.Discord.send_message("#{msg.channel_id}", "👁 Reasoning: visível")

        "off" ->
          Pincer.Core.Session.Server.set_reasoning_visible(session_id, false)

          Pincer.Channels.Discord.send_message(
            "#{msg.channel_id}",
            "🙈 Reasoning: oculto (strip ativado)"
          )

        _ ->
          Pincer.Channels.Discord.send_message("#{msg.channel_id}", "Uso: /reasoning on|off")
      end
    end

    defp handle_command(msg, "/verbose") do
      Pincer.Channels.Discord.send_message("#{msg.channel_id}", "Uso: /verbose on|off")
    end

    defp handle_command(msg, "/verbose " <> text) do
      session_context = resolve_session_context(msg)
      session_id = session_context.session_id
      ensure_brain_session_started(session_context)

      case String.trim(text) |> String.downcase() do
        "on" ->
          Pincer.Core.Session.Server.set_verbose(session_id, true)
          Pincer.Channels.Discord.send_message("#{msg.channel_id}", "🔊 Verbose: on")

        "off" ->
          Pincer.Core.Session.Server.set_verbose(session_id, false)
          Pincer.Channels.Discord.send_message("#{msg.channel_id}", "🔇 Verbose: off")

        _ ->
          Pincer.Channels.Discord.send_message("#{msg.channel_id}", "Uso: /verbose on|off")
      end
    end

    defp handle_command(msg, "/usage") do
      Pincer.Channels.Discord.send_message("#{msg.channel_id}", "Uso: /usage off|tokens|full")
    end

    defp handle_command(msg, "/usage " <> text) do
      session_context = resolve_session_context(msg)
      session_id = session_context.session_id
      ensure_brain_session_started(session_context)
      display = text |> String.trim() |> String.downcase()
      valid = ["off", "tokens", "full"]

      if display in valid do
        Pincer.Core.Session.Server.set_usage(session_id, display)
        Pincer.Channels.Discord.send_message("#{msg.channel_id}", "📊 Usage display: `#{display}`")
      else
        Pincer.Channels.Discord.send_message("#{msg.channel_id}", "Uso: /usage off|tokens|full")
      end
    end

    defp handle_command(msg, cmd) do
      Pincer.Channels.Discord.send_message(
        "#{msg.channel_id}",
        "❓ Unknown command: `#{cmd}`\n#{UX.unknown_command_hint()}"
      )
    end

    defp handle_menu_command(interaction) do
      response = %{
        type: 4,
        data: %{content: UX.help_text(:discord)}
      }

      send_interaction_response(interaction, response)
    end

    defp handle_status_command(interaction) do
      session_id = resolve_session_id(interaction)
      content = build_status_content(session_id)

      response = %{
        type: 4,
        data: %{content: content}
      }

      send_interaction_response(interaction, response)
    end

    defp handle_models_command(interaction) do
      providers = Pincer.Ports.LLM.list_providers()
      buttons = build_provider_buttons(providers)

      buttons =
        case ChannelInteractionPolicy.menu_id(:discord) do
          {:ok, id} ->
            buttons ++ [%{type: 2, style: 2, label: UX.menu_button_label(), custom_id: id}]

          _ ->
            buttons
        end

      components = chunk_buttons(buttons)

      response = %{
        type: 7,
        data: %{
          content: "🔧 **Select AI Provider:**",
          components: components
        }
      }

      send_interaction_response(interaction, response)
    end

    defp handle_kanban_command(interaction) do
      session_id = resolve_session_id(interaction)

      response = %{
        type: 4,
        data: %{content: ProjectRouter.kanban(session_id)}
      }

      send_interaction_response(interaction, response)
    end

    defp handle_project_command(interaction) do
      session_context = resolve_session_context(interaction)
      session_id = session_context.session_id

      response = %{
        type: 4,
        data: %{content: ProjectRouter.project(session_id)}
      }

      send_interaction_response(interaction, response)
      maybe_start_project_execution(read_field(interaction, :channel_id), session_context)
    end

    defp build_status_content(session_id) do
      ensure_brain_session_started(session_id)

      case Pincer.Core.Session.Server.get_status(session_id) do
        {:ok, state} ->
          provider = if state.model_override, do: state.model_override.provider, else: "Default"
          model = if state.model_override, do: state.model_override.model, else: "Default"
          status = if state.status == :working, do: "🏗️ Busy", else: "😴 Idle"

          """
          📊 **Session Status**
          ━━━━━━━━━━━━━━━
          🆔 **ID**: `#{session_id}`
          📡 **Status**: #{status}
          🏢 **Provider**: `#{provider}`
          🤖 **Model**: `#{model}`
          📜 **History**: #{length(state.history)} messages
          """

        _ ->
          "❌ Could not get session status."
      end
    end

    defp build_provider_buttons(providers) do
      providers
      |> Enum.reduce([], fn provider, acc ->
        case ChannelInteractionPolicy.provider_selector_id(:discord, provider.id) do
          {:ok, custom_id} ->
            [
              %{
                type: 2,
                style: 1,
                label: provider.name,
                custom_id: custom_id
              }
              | acc
            ]

          {:error, :payload_too_large} ->
            Logger.warning(
              "[DISCORD] Skipping provider button with oversized custom_id: #{inspect(provider.id)}"
            )

            acc

          {:error, _reason} ->
            acc
        end
      end)
      |> Enum.reverse()
    end

    defp handle_interaction(interaction) do
      # Defer formatting: Nostrum interactions usually need to be ACKed
      case ChannelInteractionPolicy.parse(:discord, read_interaction_custom_id(interaction)) do
        {:ok, {:page, provider_id, page}} ->
          models = Pincer.Ports.LLM.list_models(provider_id)
          session_id = resolve_session_id(interaction)
          current_model = current_model_for_session(session_id)

          # build_keyboard returns list of lines [[btn]], we need a flat list for chunk_buttons
          # or just pass it as is if it's already structured for Discord ActionRows.
          # Actually, Discord needs ActionRows. build_keyboard returns [[btn]], which is perfect.
          rows =
            Pincer.Core.UX.ModelKeyboard.build_keyboard(
              :discord,
              provider_id,
              models,
              page,
              current_model
            )

          # rows is [[map]], chunk_buttons expects [map]. We flatten it.
          buttons = List.flatten(rows)
          components = chunk_buttons(buttons)

          response = %{
            type: 7,
            data: %{
              content: "🤖 **Models for #{provider_id} (page #{page}):**",
              components: components
            }
          }

          send_interaction_response(interaction, response)

        {:ok, {:select_provider, provider_id}} ->
          models = Pincer.Ports.LLM.list_models(provider_id)
          session_id = resolve_session_id(interaction)
          current_model = current_model_for_session(session_id)

          rows =
            Pincer.Core.UX.ModelKeyboard.build_keyboard(
              :discord,
              provider_id,
              models,
              1,
              current_model
            )

          buttons = List.flatten(rows)
          components = chunk_buttons(buttons)

          response = %{
            # Update Message
            type: 7,
            data: %{
              content: "🤖 **Select Model for #{provider_id}:**",
              components: components
            }
          }

          send_interaction_response(interaction, response)

        {:ok, {:select_model, provider_id, model}} ->
          session_context = resolve_session_context(interaction)
          session_id = session_context.session_id

          ensure_brain_session_started(session_context)
          Server.set_model(session_id, provider_id, model)

          response = %{
            type: 7,
            data: %{
              content:
                "✅ **Model configured!**\nSession: `#{session_id}`\nProvider: `#{provider_id}`\nModel: `#{model}`",
              # Remove buttons
              components: []
            }
          }

          send_interaction_response(interaction, response)

        {:ok, :back_to_providers} ->
          providers = Pincer.Ports.LLM.list_providers()
          buttons = build_provider_buttons(providers)

          buttons =
            case ChannelInteractionPolicy.menu_id(:discord) do
              {:ok, id} ->
                buttons ++ [%{type: 2, style: 2, label: UX.menu_button_label(), custom_id: id}]

              _ ->
                buttons
            end

          components = chunk_buttons(buttons)

          response = %{
            type: 7,
            data: %{
              content: "🔧 **Select AI Provider:**",
              components: components
            }
          }

          send_interaction_response(interaction, response)

        {:ok, :show_menu} ->
          response = %{
            type: 7,
            data: %{
              content: UX.help_text(:discord),
              components: []
            }
          }

          send_interaction_response(interaction, response)

        {:error, _reason} ->
          send_interaction_response(interaction, unknown_interaction_response())
      end
    end

    defp current_model_for_session(session_id) do
      case Pincer.Core.Session.Server.get_status(session_id) do
        {:ok, %{model_override: %{model: model}}} -> model
        _ -> nil
      end
    rescue
      _ -> nil
    end

    defp unknown_interaction_response do
      menu_btn =
        case ChannelInteractionPolicy.menu_id(:discord) do
          {:ok, id} -> [%{type: 2, style: 2, label: UX.menu_button_label(), custom_id: id}]
          _ -> []
        end

      %{
        type: 7,
        data: %{
          content: "❓ #{UX.unknown_interaction_hint()}\n#{UX.unknown_command_hint()}",
          components: chunk_buttons(menu_btn)
        }
      }
    end

    defp maybe_start_project_execution(channel_id, %Pincer.Core.Session.Context{} = context)
         when not is_nil(channel_id) do
      case ProjectRouter.kickoff(context.session_id) do
        {:ok, kickoff} ->
          ensure_brain_session_started(context)
          Pincer.Channels.Discord.Session.ensure_started(channel_id, context.session_id)

          Pincer.Channels.Discord.send_message(
            "#{channel_id}",
            "Project Runner: #{kickoff.status_message}"
          )

          _ = Server.process_input(context.session_id, kickoff.prompt)
          :ok

        :not_ready ->
          :ok

        :already_started ->
          :ok

        :completed ->
          :ok
      end
    end

    defp maybe_start_project_execution(_channel_id, _session_context), do: :ok

    defp ensure_brain_session_started(%Pincer.Core.Session.Context{} = context) do
      start_opts =
        context
        |> Pincer.Core.Session.Context.to_start_opts()
        |> Keyword.delete(:session_id)

      case Registry.lookup(Pincer.Core.Session.Registry, context.session_id) do
        [] ->
          Logger.info(
            "[DISCORD] Creating new brain session: #{context.session_id} (root_agent=#{context.root_agent_id})"
          )

          Pincer.Core.Session.Supervisor.start_session(context.session_id, start_opts)

        [_] ->
          :ok
      end
    end

    defp ensure_brain_session_started(session_id) do
      case Registry.lookup(Pincer.Core.Session.Registry, session_id) do
        [] ->
          Logger.info("[DISCORD] Creating new brain session: #{session_id}")
          Pincer.Core.Session.Supervisor.start_session(session_id)

        [_] ->
          :ok
      end
    end

    defp chunk_buttons(buttons) do
      buttons
      |> Enum.chunk_every(5)
      |> Enum.map(fn chunk -> %{type: 1, components: chunk} end)
    end

    defp read_interaction_custom_id(interaction) when is_map(interaction) do
      interaction
      |> read_field(:data)
      |> read_field(:custom_id)
    end

    defp read_interaction_custom_id(_), do: nil

    defp send_interaction_response(interaction, response) do
      with {:ok, interaction_id} <- normalize_interaction_id(read_field(interaction, :id)),
           {:ok, interaction_token} <-
             normalize_interaction_token(read_field(interaction, :token)) do
        case Pincer.Channels.Discord.api_client().create_interaction_response(
               interaction_id,
               interaction_token,
               response
             ) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error("[DISCORD] Failed to send interaction response: #{inspect(reason)}")
        end
      else
        {:error, :invalid_interaction_id} ->
          Logger.warning(
            "[DISCORD] Ignoring interaction response: missing/invalid interaction id."
          )

          :ok

        {:error, :invalid_interaction_token} ->
          Logger.warning(
            "[DISCORD] Ignoring interaction response: missing/invalid interaction token."
          )

          :ok
      end
    end

    defp normalize_interaction_id(value) when is_integer(value) and value > 0,
      do: {:ok, value}

    defp normalize_interaction_id(value) when is_binary(value) do
      case Integer.parse(String.trim(value)) do
        {id, ""} when id > 0 -> {:ok, id}
        _ -> {:error, :invalid_interaction_id}
      end
    end

    defp normalize_interaction_id(_), do: {:error, :invalid_interaction_id}

    defp normalize_interaction_token(value) when is_binary(value) do
      token = String.trim(value)
      if token == "", do: {:error, :invalid_interaction_token}, else: {:ok, token}
    end

    defp normalize_interaction_token(_), do: {:error, :invalid_interaction_token}

    # Extensions whose content is extracted inline as text (small, structured files).
    @text_extensions ~w(.md .txt .ex .exs .json .yaml .yml .py .js .ts .csv .xml .toml)

    # Extensions handled as lazy multimodal references — the Executor decides
    # whether to inline them (base64) or just describe them based on the active
    # provider's capabilities.
    @multimodal_mime %{
      ".pdf" => "application/pdf",
      ".png" => "image/png",
      ".jpg" => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".webp" => "image/webp",
      ".gif" => "image/gif"
    }

    # Returns {inline_text :: String.t(), attachment_refs :: [map()]}
    # inline_text  — text extracted immediately from plain-text attachments
    # attachment_refs — lazy maps for binary/multimodal files (resolved later by the Executor)
    defp process_attachments(attachments) when is_list(attachments) and attachments != [] do
      Logger.info("[DISCORD] Processing #{length(attachments)} attachments.")

      Enum.reduce(attachments, {"", []}, fn attachment, {texts, refs} ->
        ext = Path.extname(attachment.filename) |> String.downcase()
        meta = "[Attachment: #{attachment.filename} (#{attachment.size} bytes)]"

        cond do
          ext in @text_extensions ->
            content = download_attachment(attachment)
            {texts <> "\n\n" <> meta <> "\n" <> content, refs}

          Map.has_key?(@multimodal_mime, ext) ->
            ref = %{
              "type" => "attachment_ref",
              "url" => attachment.url,
              "mime_type" => @multimodal_mime[ext],
              "filename" => attachment.filename,
              "size" => attachment.size
            }

            {texts, refs ++ [ref]}

          true ->
            {texts <> "\n\n" <> meta <> " (formato não suportado)", refs}
        end
      end)
    end

    defp process_attachments(_), do: {"", []}

    # 25 MB — aligns with Discord's own limit for free accounts. Prevents
    # downloading payloads larger than what Discord itself would have accepted.
    @max_attachment_size 26_214_400

    defp download_attachment(attachment) do
      Logger.info("[DISCORD] Reading text from attachment: #{attachment.filename}")

      # Reject before download if the declared size already exceeds the limit.
      if attachment.size > @max_attachment_size do
        Logger.warning(
          "[DISCORD] Attachment too large (#{attachment.size} bytes): #{attachment.filename}"
        )

        "(Error: File too large — #{attachment.size} bytes exceeds the #{@max_attachment_size}-byte limit)"
      else
        case Req.get(attachment.url,
               max_body_length: @max_attachment_size,
               receive_timeout: 30_000,
               connect_timeout: 10_000
             ) do
          {:ok, %{status: 200, body: content, headers: headers}} ->
            content_type =
              case Req.Response.get_header(
                     %Req.Response{headers: headers, status: 200, body: content},
                     "content-type"
                   ) do
                [ct | _] -> ct
                _ -> ""
              end

            if valid_text_content_type?(content_type) do
              safe_name = sanitize_filename(attachment.filename)
              "--- Content of #{safe_name} ---\n#{content}\n--- End of File ---"
            else
              Logger.warning("[DISCORD] Rejected attachment with content-type: #{content_type}")
              "(Error: Unsupported content type '#{content_type}')"
            end

          {:ok, %{status: status}} ->
            Logger.error("[DISCORD] Failed to download #{attachment.filename}: HTTP #{status}")
            "(Error: Could not download file content)"

          {:error, reason} ->
            Logger.error("[DISCORD] Error downloading #{attachment.filename}: #{inspect(reason)}")
            "(Error: Connection failed during download)"
        end
      end
    end

    @allowed_content_type_prefixes [
      "text/",
      "application/json",
      "application/x-yaml",
      "application/yaml"
    ]

    defp valid_text_content_type?(ct) do
      ct = String.downcase(ct)
      Enum.any?(@allowed_content_type_prefixes, &String.starts_with?(ct, &1))
    end

    defp sanitize_filename(filename) do
      # Strip characters that could be used for injection or display tricks.
      String.replace(filename, ~r/[<>&"'\x00-\x1F]/, "_")
    end
  end

  def register_commands do
    policy = MenuPolicy.registerable_commands(:discord, UX.commands())

    Enum.each(policy.issues, fn issue ->
      Logger.warning("[DISCORD] Command policy issue: #{issue}")
    end)

    case api_client().bulk_overwrite_global_commands(policy.commands) do
      {:ok, _} ->
        Logger.info("[DISCORD] Slash Commands registered successfully.")

      {:error, reason} ->
        Logger.error("[DISCORD] Failed to register Slash Commands: #{inspect(reason)}")

      _ ->
        :ok
    end
  end

  def api_client do
    Application.get_env(:pincer, :discord_api, Pincer.Channels.Discord.API.Adapter)
  end
end
