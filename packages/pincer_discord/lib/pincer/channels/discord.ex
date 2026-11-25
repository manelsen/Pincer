defmodule Pincer.Channels.Discord do
  @moduledoc """
  Discord channel adapter using Nostrum.

  This module handles:
  - Receiving messages from Discord and routing to sessions
  - Sending messages from sessions back to Discord
  - Formatting Pincer Markdown to Discord-flavored Markdown
  """
  @behaviour PincerPorts.Channel
  use Supervisor
  require Logger
  alias Pincer.Channels.Shared.{Attachments, Chunking, Formatting}

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
      Pincer.Channels.Discord.SessionSupervisor,
      {Pincer.Channels.Discord.Consumer, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Sends a message to a Discord channel.
  """
  @impl PincerPorts.Channel
  def send_message(channel_id, text, opts \\ []) do
    # 1. Handle auto-attachments (extract large code blocks)
    {text, files} = Attachments.extract_large_code_blocks(text, opts[:files] || [])

    # 2. Split text into manageable chunks
    formatted_text = markdown_to_discord(text)
    chunks = split_into_chunks(formatted_text, 1900)

    # 3. Transmit to Discord
    do_send_chunks(String.to_integer(channel_id), chunks, files, opts)
  end

  @doc """
  Updates an existing Discord message.
  """
  @impl PincerPorts.Channel
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
    nostrum_opts = build_nostrum_opts(first, files, opts)

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
    nostrum_opts = build_nostrum_opts("", files, opts)

    case api_client().create_message(channel_id, "", nostrum_opts) do
      {:ok, %{id: mid}} -> {:ok, mid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_send_chunks(_, [], [], _), do: :ok

  defp build_nostrum_opts(content, files, opts) do
    nostrum_opts = if Enum.any?(files), do: [files: files], else: []

    nostrum_opts =
      if opts[:components],
        do: [{:components, opts[:components]} | nostrum_opts],
        else: nostrum_opts

    [{:content, content} | nostrum_opts]
  end

  def split_into_chunks(text, max_len) do
    Chunking.split(text, max_len, strategy: :newline_window, search_range: 500)
  end

  @doc """
  Converts Pincer-standard Markdown to Discord-flavored Markdown.
  """
  def markdown_to_discord(text) do
    Formatting.markdown_to_discord(text)
  end

  defmodule Consumer do
    @moduledoc """
    Consumes Discord events and routes messages to Pincer sessions.
    """
    use Nostrum.Consumer
    alias Pincer.Channels.Shared.{Attachments, Inbound, Pairing}

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
              session_context = resolve_session_context(msg)
              session_id = session_context.session_id

              inbound = %{
                text: trimmed,
                # A captioned attachment must not be routed as text-only: the
                # project wizard would consume the caption and the file would
                # never be delivered.
                has_attachments: msg.attachments != nil and msg.attachments != [],
                session_id: session_id,
                on_command: fn command -> handle_command(msg, command) end,
                on_message: fn _content -> :ok end,
                on_project_response: fn response, _sid ->
                  Pincer.Channels.Discord.send_message("#{msg.channel_id}", response)
                  maybe_start_project_execution(msg.channel_id, session_context)
                end
              }

              case Inbound.dispatch(inbound,
                     resolve_shortcut: &PincerPorts.UX.resolve_shortcut/1,
                     continue_project: &Pincer.Channels.Shared.ProjectBridge.continue/3
                   ) do
                {:message, _content} ->
                  deliver_inbound_message(msg, session_context, trimmed)

                _other ->
                  :ok
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
      dm_event?(msg) and Pairing.pair_command?(trimmed)
    end

    defp authorize_dm_if_needed(msg) do
      sender_id = read_sender_id(msg.author)
      policy_config = Application.get_env(:pincer, :discord_channel_config, %{})
      Pairing.authorize_dm(:discord, sender_id, policy_config, is_dm: dm_event?(msg))
    end

    defp dm_event?(msg), do: Map.get(msg, :guild_id) in [nil, ""]

    defp deliver_inbound_message(msg, session_context, trimmed) do
      Logger.info("[DISCORD] Message from #{msg.author.username} in #{msg.channel_id}")

      session_id = session_context.session_id
      {attachment_text, attachment_refs} = process_attachments(msg.attachments)

      case Attachments.combine_content(trimmed, attachment_text, attachment_refs) do
        :empty ->
          Logger.debug("[DISCORD] Ignoring empty message without supported attachments.")

        {:ok, full_content} ->
          ensure_brain_session_started(session_context)
          Pincer.Channels.Discord.Session.ensure_started(msg.channel_id, session_id)

          PincerPorts.Session.process_input(
            session_id,
            Attachments.to_incoming_message(session_id, full_content)
          )
      end
    end

    defp read_sender_id(author) when is_map(author) do
      Map.get(author, :id) || Map.get(author, "id") || Map.get(author, :username) ||
        Map.get(author, "username") || "unknown"
    end

    defp read_sender_id(_), do: "unknown"

    defp resolve_session_context(context) do
      policy_config = Application.get_env(:pincer, :discord_channel_config, %{})
      sender_id = resolve_sender_id(context)

      PincerPorts.Session.resolve(
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
            data: %{
              content:
                "❓ Unknown command: `#{command_name}`\n#{PincerPorts.UX.unknown_command_hint()}"
            }
          }

          send_interaction_response(interaction, response)
      end
    end

    defp handle_command(msg, "/ping") do
      Pincer.Channels.Discord.send_message("#{msg.channel_id}", "Pong! 🏓")
    end

    defp handle_command(msg, "/menu") do
      Pincer.Channels.Discord.send_message(
        "#{msg.channel_id}",
        PincerPorts.UX.help_text(:discord)
      )
    end

    defp handle_command(msg, "/status") do
      session_id = resolve_session_id(msg)
      content = build_status_content(session_id)
      Pincer.Channels.Discord.send_message("#{msg.channel_id}", content)
    end

    defp handle_command(msg, "/models") do
      providers = PincerPorts.LLM.list_providers()
      buttons = build_provider_buttons(providers)

      buttons =
        case PincerPorts.ChannelPolicy.menu_id(:discord) do
          {:ok, id} ->
            buttons ++
              [%{type: 2, style: 2, label: PincerPorts.UX.menu_button_label(), custom_id: id}]

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
        PincerPorts.Project.kanban(session_id)
      )
    end

    defp handle_command(msg, "/project") do
      session_context = resolve_session_context(msg)
      session_id = session_context.session_id
      response = PincerPorts.Project.project(session_id)
      Pincer.Channels.Discord.send_message("#{msg.channel_id}", response)
      maybe_start_project_execution(msg.channel_id, session_context)
    end

    defp handle_command(msg, "/project " <> details) do
      session_context = resolve_session_context(msg)
      session_id = session_context.session_id
      response = PincerPorts.Project.project(session_id, details)
      Pincer.Channels.Discord.send_message("#{msg.channel_id}", response)
      maybe_start_project_execution(msg.channel_id, session_context)
    end

    defp handle_command(msg, "/pair") do
      handle_pairing(msg, "")
    end

    defp handle_command(msg, "/pair " <> code_input) do
      handle_pairing(msg, code_input)
    end

    defp handle_command(msg, "/new") do
      session_context = resolve_session_context(msg)
      session_id = session_context.session_id
      ensure_brain_session_started(session_context)

      case PincerPorts.Session.reset(session_id) do
        :ok ->
          Pincer.Channels.Discord.send_message("#{msg.channel_id}", "🔄 Session reset.")

        _ ->
          Pincer.Channels.Discord.send_message(
            "#{msg.channel_id}",
            "❌ Could not reset the session."
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
          PincerPorts.Session.set_model(session_id, provider, model)

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
        PincerPorts.Session.set_thinking(session_id, level)
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
          PincerPorts.Session.set_reasoning_visible(session_id, true)
          Pincer.Channels.Discord.send_message("#{msg.channel_id}", "👁 Reasoning: visible")

        "off" ->
          PincerPorts.Session.set_reasoning_visible(session_id, false)

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
          PincerPorts.Session.set_verbose(session_id, true)
          Pincer.Channels.Discord.send_message("#{msg.channel_id}", "🔊 Verbose: on")

        "off" ->
          PincerPorts.Session.set_verbose(session_id, false)
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
        PincerPorts.Session.set_usage(session_id, display)
        Pincer.Channels.Discord.send_message("#{msg.channel_id}", "📊 Usage display: `#{display}`")
      else
        Pincer.Channels.Discord.send_message("#{msg.channel_id}", "Uso: /usage off|tokens|full")
      end
    end

    defp handle_command(msg, cmd) do
      Pincer.Channels.Discord.send_message(
        "#{msg.channel_id}",
        "❓ Unknown command: `#{cmd}`\n#{PincerPorts.UX.unknown_command_hint()}"
      )
    end

    defp handle_pairing(msg, code_input) do
      sender_id = read_sender_id(msg.author)

      message =
        case Pairing.approve(:discord, sender_id, code_input) do
          {:ok, text} -> text
          {:error, _reason, text} -> text
        end

      Pincer.Channels.Discord.send_message("#{msg.channel_id}", message)
    end

    defp handle_menu_command(interaction) do
      response = %{
        type: 4,
        data: %{content: PincerPorts.UX.help_text(:discord)}
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
      providers = PincerPorts.LLM.list_providers()
      buttons = build_provider_buttons(providers)

      buttons =
        case PincerPorts.ChannelPolicy.menu_id(:discord) do
          {:ok, id} ->
            buttons ++
              [%{type: 2, style: 2, label: PincerPorts.UX.menu_button_label(), custom_id: id}]

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
        data: %{content: PincerPorts.Project.kanban(session_id)}
      }

      send_interaction_response(interaction, response)
    end

    defp handle_project_command(interaction) do
      session_context = resolve_session_context(interaction)
      session_id = session_context.session_id

      response = %{
        type: 4,
        data: %{content: PincerPorts.Project.project(session_id)}
      }

      send_interaction_response(interaction, response)
      maybe_start_project_execution(read_field(interaction, :channel_id), session_context)
    end

    defp build_status_content(session_id) do
      ensure_brain_session_started(session_id)

      try do
        case PincerPorts.Session.get_status(session_id) do
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
      catch
        :exit, {:timeout, _} -> "⏳ Session is starting up, please try again shortly."
      end
    end

    defp build_provider_buttons(providers) do
      providers
      |> Enum.reduce([], fn provider, acc ->
        case PincerPorts.ChannelPolicy.provider_selector_id(:discord, provider.id) do
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
      case PincerPorts.ChannelPolicy.parse(:discord, read_interaction_custom_id(interaction)) do
        {:ok, {:page, provider_id, page}} ->
          models = PincerPorts.LLM.list_models(provider_id)
          session_id = resolve_session_id(interaction)
          current_model = current_model_for_session(session_id)

          # build_keyboard returns list of lines [[btn]], we need a flat list for chunk_buttons
          # or just pass it as is if it's already structured for Discord ActionRows.
          # Actually, Discord needs ActionRows. build_keyboard returns [[btn]], which is perfect.
          rows =
            PincerPorts.UX.build_keyboard(
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
          models = PincerPorts.LLM.list_models(provider_id)
          session_id = resolve_session_id(interaction)
          current_model = current_model_for_session(session_id)

          rows =
            PincerPorts.UX.build_keyboard(
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
          PincerPorts.Session.set_model(session_id, provider_id, model)

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
          providers = PincerPorts.LLM.list_providers()
          buttons = build_provider_buttons(providers)

          buttons =
            case PincerPorts.ChannelPolicy.menu_id(:discord) do
              {:ok, id} ->
                buttons ++
                  [
                    %{
                      type: 2,
                      style: 2,
                      label: PincerPorts.UX.menu_button_label(),
                      custom_id: id
                    }
                  ]

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
              content: PincerPorts.UX.help_text(:discord),
              components: []
            }
          }

          send_interaction_response(interaction, response)

        {:ok, {:approval, decision}} ->
          session_context = resolve_session_context(interaction)
          ensure_brain_session_started(session_context)
          answer = if decision == :approved, do: "aprovo", else: "rejeito"
          PincerPorts.Session.process_input(session_context.session_id, answer)
          label = if decision == :approved, do: "✅ Aprovado", else: "❌ Rejeitado"

          response = %{
            type: 7,
            data: %{content: label, components: []}
          }

          send_interaction_response(interaction, response)

        {:error, _reason} ->
          send_interaction_response(interaction, unknown_interaction_response())
      end
    end

    defp current_model_for_session(session_id) do
      case PincerPorts.Session.get_status(session_id) do
        {:ok, %{model_override: %{model: model}}} -> model
        _ -> nil
      end
    rescue
      _ -> nil
    end

    defp unknown_interaction_response do
      menu_btn =
        case PincerPorts.ChannelPolicy.menu_id(:discord) do
          {:ok, id} ->
            [%{type: 2, style: 2, label: PincerPorts.UX.menu_button_label(), custom_id: id}]

          _ ->
            []
        end

      %{
        type: 7,
        data: %{
          content:
            "❓ #{PincerPorts.UX.unknown_interaction_hint()}\n#{PincerPorts.UX.unknown_command_hint()}",
          components: chunk_buttons(menu_btn)
        }
      }
    end

    defp maybe_start_project_execution(channel_id, %PincerPorts.Session.Context{} = context)
         when not is_nil(channel_id) do
      Pincer.Channels.Shared.ProjectBridge.kickoff(context.session_id,
        ensure_session: fn -> ensure_brain_session_started(context) end,
        ensure_worker: fn ->
          Pincer.Channels.Discord.Session.ensure_started(channel_id, context.session_id)
        end,
        send_message: fn text -> Pincer.Channels.Discord.send_message("#{channel_id}", text) end,
        log_tag: "DISCORD"
      )
    end

    defp maybe_start_project_execution(_channel_id, _session_context), do: :ok

    defp ensure_brain_session_started(%PincerPorts.Session.Context{} = context) do
      Pincer.Channels.Shared.SessionBridge.ensure_started(context,
        on_start: fn sid ->
          Logger.info(
            "[DISCORD] Creating new brain session: #{sid} (root_agent=#{context.root_agent_id})"
          )
        end
      )
    end

    defp ensure_brain_session_started(session_id) do
      Pincer.Channels.Shared.SessionBridge.ensure_started(session_id,
        on_start: fn sid -> Logger.info("[DISCORD] Creating new brain session: #{sid}") end
      )
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

    # Returns {inline_text :: String.t(), attachment_refs :: [map()]}
    # inline_text  — text extracted immediately from plain-text attachments
    # attachment_refs — lazy maps for binary/multimodal files (resolved later by the Executor)
    defp process_attachments(attachments) when is_list(attachments) and attachments != [] do
      Logger.info("[DISCORD] Processing #{length(attachments)} attachments.")
      Attachments.process_list(attachments, download_text: &download_attachment/1)
    end

    defp process_attachments(_), do: {"", []}

    # 25 MB — aligns with Discord's own limit for free accounts. Prevents
    # downloading payloads larger than what Discord itself would have accepted.
    @max_attachment_size 26_214_400

    defp download_attachment(attachment) do
      Logger.info("[DISCORD] Reading text from attachment: #{attachment.filename}")

      # Reject before download if the declared size already exceeds the limit.
      case Attachments.validate_size(attachment.size, @max_attachment_size) do
        {:error, :too_large} ->
          Logger.warning(
            "[DISCORD] Attachment too large (#{attachment.size} bytes): #{attachment.filename}"
          )

          "(Error: File too large — #{attachment.size} bytes exceeds the #{@max_attachment_size}-byte limit)"

        :ok ->
          case Req.get(attachment.url,
                 decode_body: false,
                 receive_timeout: 30_000,
                 connect_options: [timeout: 10_000],
                 into: fn {:data, chunk}, {request, response} ->
                   body = (response.body || "") <> chunk
                   response = %{response | body: body}

                   if byte_size(body) > @max_attachment_size do
                     {:halt, {request, response}}
                   else
                     {:cont, {request, response}}
                   end
                 end
               ) do
            {:ok, %{status: 200, body: content, headers: headers}}
            when is_binary(content) and byte_size(content) <= @max_attachment_size ->
              content_type =
                case Req.Response.get_header(
                       %Req.Response{headers: headers, status: 200, body: content},
                       "content-type"
                     ) do
                  [ct | _] -> ct
                  _ -> ""
                end

              if Attachments.valid_text_content_type?(content_type) do
                Attachments.format_inline_file(attachment.filename, content)
              else
                Logger.warning("[DISCORD] Rejected attachment with content-type: #{content_type}")

                "(Error: Unsupported content type '#{content_type}')"
              end

            {:ok, %{status: 200}} ->
              Logger.warning("[DISCORD] Attachment too large: #{attachment.filename}")
              "(Error: File too large — download exceeded the limit)"

            {:ok, %{status: status}} ->
              Logger.error("[DISCORD] Failed to download #{attachment.filename}: HTTP #{status}")
              "(Error: Could not download file content)"

            {:error, reason} ->
              Logger.error(
                "[DISCORD] Error downloading #{attachment.filename}: #{inspect(reason)}"
              )

              "(Error: Connection failed during download)"
          end
      end
    end
  end

  def register_commands do
    policy = PincerPorts.UX.registerable_commands(:discord, PincerPorts.UX.commands())

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
