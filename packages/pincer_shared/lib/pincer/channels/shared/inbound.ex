defmodule Pincer.Channels.Shared.Inbound do
  @moduledoc """
  Channel-agnostic inbound message pipeline.

  Every chat adapter (Telegram, Discord, WhatsApp, DingTalk, LINE, Feishu, Slack)
  walks the same decision tree before handing a message to the session:

      1. DM policy & pairing gate (optional via `route/2`) -> :denied / :command
      2. is it a slash command?                           -> :command
      3. does it resolve to a UX shortcut?                -> :shortcut
      4. is a project wizard collecting?                  -> :project
      5. otherwise                                        -> :message

  The wording of the branches, their order and the attachment handling are easy
  to get subtly wrong per adapter, so this module owns the decision and the
  adapter owns the actions. It deliberately has **no dependency on
  `Pincer.Core`**: the caller passes the few operations that need Core as
  functions (or routes through `PincerPorts`), which keeps `pincer_shared`
  publishable on its own.

  ## Example

      Shared.Inbound.dispatch(inbound,
        resolve_shortcut: &UX.resolve_shortcut/1,
        continue_project: fn sid, text, opts -> ProjectRouter.continue_if_collecting(sid, text, opts) end
      )

  ## Callbacks: the `inbound` map

    * `:channel` - optional channel atom (`:telegram`, `:dingtalk`, etc.) for DM gating
    * `:sender_id` - optional sender identifier used when checking DM access policy
    * `:is_dm` - optional boolean (defaults to `false`)
    * `:config` - optional channel config map for DM access policy (defaults to `%{}`)
    * `:text` - the raw text, or `nil` when the payload is attachment-only
    * `:has_attachments` - boolean
    * `:session_id` - resolved session id for the sender
    * `:on_command` - `fn text -> result end`, invoked for slash commands and
      shortcuts with the command string
    * `:on_project_response` - `fn response, session_id -> any end`, invoked when
      a project wizard consumed the message
    * `:on_message` - `fn text_or_content -> result end`, invoked for a normal
      message
    * `:on_denied` - optional `fn message -> any end`, invoked when DM policy denies access
    * `:on_ignored` - optional `fn reason -> any end`, invoked when nothing runs
  """

  alias Pincer.Channels.Shared.{Pairing, ProjectBridge}
  alias PincerPorts.Structs.IncomingMessage

  @type result ::
          {:command, term()}
          | {:shortcut, term()}
          | {:project, term()}
          | {:message, term()}
          | {:denied, String.t()}
          | {:ignored, atom()}

  @type inbound :: %{
          required(:text) => String.t() | nil,
          required(:has_attachments) => boolean(),
          required(:session_id) => String.t() | nil,
          required(:on_command) => (String.t() -> term()),
          required(:on_message) => (term() -> term()),
          optional(:channel) => atom(),
          optional(:sender_id) => term(),
          optional(:is_dm) => boolean(),
          optional(:config) => map(),
          optional(:on_project_response) => (term(), String.t() -> term()),
          optional(:on_denied) => (String.t() -> term()),
          optional(:on_ignored) => (atom() -> term())
        }

  @type opts :: [
          resolve_shortcut: (String.t() -> {:ok, String.t()} | :error),
          continue_project: (String.t(), String.t(), keyword() ->
                               {:handled, term()} | :not_handled),
          policy_module: module(),
          enforce_dm_policy: boolean()
        ]

  @doc """
  Full inbound routing entrypoint used by channel adapters.

  Handles blank payloads (`:empty`), bypasses the DM gate for `/pair` commands
  in DMs, enforces `Pincer.Channels.Shared.Pairing.authorize_dm/4` when
  `:is_dm` is `true`, and delegates to `dispatch/2` (defaulting
  `:resolve_shortcut` to `PincerPorts.UX.resolve_shortcut/1` and
  `:continue_project` to `Pincer.Channels.Shared.ProjectBridge.continue/3`).
  """
  @spec route(map(), opts()) :: result()
  def route(inbound, opts \\ []) when is_map(inbound) and is_list(opts) do
    raw_text = Map.get(inbound, :text)
    has_attachments = Map.get(inbound, :has_attachments, false)
    trimmed = if is_binary(raw_text), do: String.trim(raw_text), else: nil
    is_dm? = Map.get(inbound, :is_dm, false)
    enforce_dm? = Keyword.get(opts, :enforce_dm_policy, true)
    channel = Map.get(inbound, :channel)

    dispatch_opts =
      opts
      |> Keyword.put_new(:resolve_shortcut, &PincerPorts.UX.resolve_shortcut/1)
      |> Keyword.put_new(:continue_project, &ProjectBridge.continue/3)

    cond do
      not has_attachments and (is_nil(trimmed) or trimmed == "") ->
        ignore(inbound, :empty)

      is_dm? and not has_attachments and is_binary(trimmed) and Pairing.pair_command?(trimmed) ->
        {:command, command!(inbound, trimmed)}

      enforce_dm? and is_dm? and is_atom(channel) and not is_nil(channel) ->
        policy_module = Keyword.get(opts, :policy_module, PincerPorts.ChannelPolicy)
        sender_id = Map.get(inbound, :sender_id)
        config = Map.get(inbound, :config, %{})

        case Pairing.authorize_dm(channel, sender_id, config,
               is_dm: true,
               policy_module: policy_module
             ) do
          :allow ->
            normalized = Map.put(inbound, :text, trimmed)
            dispatch(normalized, dispatch_opts)

          {:deny, message} ->
            deny(inbound, message)
        end

      true ->
        normalized =
          if is_binary(trimmed) do
            Map.put(inbound, :text, trimmed)
          else
            inbound
          end

        dispatch(normalized, dispatch_opts)
    end
  end

  @doc """
  Executes common slash commands (`/ping`, `/menu`, `/help`, `/commands`,
  `/new`, `/reset`, `/kanban`, `/project`, `/pair`) for channel adapters that do
  not implement custom interactive menus.
  """
  @spec handle_standard_command(String.t(), map(), keyword()) :: term()
  def handle_standard_command(command_text, context, opts \\ [])
      when is_binary(command_text) and is_map(context) and is_list(opts) do
    {cmd, args} = split_command(command_text)
    cmd = String.downcase(cmd)

    channel = Map.fetch!(context, :channel)
    session_id = Map.fetch!(context, :session_id)
    send_reply = Map.fetch!(context, :send_reply)
    sender_id = Map.get(context, :sender_id)
    is_dm? = Map.get(context, :is_dm, false)

    ux_module = Keyword.get(opts, :ux_module, PincerPorts.UX)
    session_module = Keyword.get(opts, :session_module, PincerPorts.Session)
    project_module = Keyword.get(opts, :project_module, PincerPorts.Project)
    policy_module = Keyword.get(opts, :policy_module, PincerPorts.ChannelPolicy)

    case cmd do
      "/ping" ->
        send_reply.("Pong! 🏓")

      command when command in ["/menu", "/help", "/commands"] ->
        send_reply.(ux_module.help_text(channel))

      command when command in ["/new", "/reset"] ->
        run_zero_arity(Map.get(context, :ensure_session))

        case session_module.reset(session_id) do
          :ok -> send_reply.("🔄 Session reset.")
          _ -> send_reply.("❌ Could not reset the session.")
        end

      "/kanban" ->
        send_reply.(project_module.kanban(session_id))

      "/project" ->
        seed = if args == "", do: nil, else: args
        send_reply.(project_module.project(session_id, seed))
        run_zero_arity(Map.get(context, :on_project_kickoff))

      "/pair" ->
        message =
          case Pairing.approve(channel, sender_id, args,
                 is_dm: is_dm?,
                 policy_module: policy_module
               ) do
            {:ok, text} -> text
            {:error, _reason, text} -> text
          end

        send_reply.(message)

      _other ->
        send_reply.("Unknown command: #{cmd}\n#{ux_module.unknown_command_hint()}")
    end
  end

  @doc """
  Starts the session and optional channel worker before delivering `content`
  to `PincerPorts.Session.process_input/2`.
  """
  @spec dispatch_session_message(String.t(), String.t() | IncomingMessage.t(), keyword()) ::
          :ok | {:error, term()}
  def dispatch_session_message(session_id, content, opts \\ [])
      when is_binary(session_id) and is_list(opts) do
    run_zero_arity(Keyword.get(opts, :ensure_session))
    run_zero_arity(Keyword.get(opts, :ensure_worker))

    session_module = Keyword.get(opts, :session_module, PincerPorts.Session)

    incoming =
      case content do
        %IncomingMessage{} = msg -> msg
        text when is_binary(text) -> IncomingMessage.new(session_id, text)
      end

    case session_module.process_input(session_id, incoming) do
      :ok -> :ok
      {:ok, _status} -> :ok
      {:error, reason} -> {:error, reason}
      _other -> :ok
    end
  end

  @doc """
  Runs the inbound decision tree.

  Command and shortcut branches win over project collection, which in turn wins
  over normal message handling.

  Any payload carrying attachments goes straight to message handling, so a
  slash command sent together with a file is delivered as a message rather than
  executed as a command. Attachment-only payloads therefore take the same
  path as captioned ones.
  """
  @spec dispatch(inbound(), opts()) :: result()
  def dispatch(inbound, opts \\ []) do
    text = Map.get(inbound, :text)
    has_attachments = Map.get(inbound, :has_attachments, false)

    cond do
      is_binary(text) and not has_attachments and slash_command?(text) ->
        {:command, command!(inbound, text)}

      is_binary(text) and not has_attachments ->
        dispatch_text(inbound, text, opts)

      has_attachments ->
        {:message, message!(inbound, text)}

      true ->
        ignore(inbound, :unsupported)
    end
  end

  @doc "True when the trimmed text starts a slash command."
  @spec slash_command?(String.t()) :: boolean()
  def slash_command?(text) when is_binary(text), do: String.starts_with?(String.trim(text), "/")
  def slash_command?(_), do: false

  @doc """
  Splits a slash command into `{command, arguments}`.

      iex> Pincer.Channels.Shared.Inbound.split_command("/think high extra")
      {"/think", "high extra"}
  """
  @spec split_command(String.t()) :: {String.t(), String.t()}
  def split_command(text) when is_binary(text) do
    [cmd | rest] = text |> String.trim() |> String.split(" ")
    {cmd, Enum.join(rest, " ")}
  end

  defp dispatch_text(inbound, text, opts) do
    resolve = Keyword.get(opts, :resolve_shortcut, fn _ -> :error end)

    case resolve.(text) do
      {:ok, command} ->
        {:shortcut, command!(inbound, command)}

      :error ->
        dispatch_project(inbound, text, opts)
    end
  end

  defp dispatch_project(inbound, text, opts) do
    continue = Keyword.get(opts, :continue_project)
    session_id = Map.get(inbound, :session_id)

    if is_function(continue, 3) and is_binary(session_id) do
      case continue.(session_id, text, has_attachments: false) do
        {:handled, response} ->
          {:project, project!(inbound, response, session_id)}

        :not_handled ->
          {:message, message!(inbound, text)}
      end
    else
      {:message, message!(inbound, text)}
    end
  end

  defp command!(inbound, command), do: inbound.on_command.(command)
  defp message!(inbound, content), do: inbound.on_message.(content)

  defp project!(inbound, response, session_id) do
    case Map.get(inbound, :on_project_response) do
      fun when is_function(fun, 2) -> fun.(response, session_id)
      _ -> response
    end
  end

  defp deny(inbound, message) do
    case Map.get(inbound, :on_denied) do
      fun when is_function(fun, 1) -> fun.(message)
      _ -> :ok
    end

    {:denied, message}
  end

  defp ignore(inbound, reason) do
    case Map.get(inbound, :on_ignored) do
      fun when is_function(fun, 1) -> fun.(reason)
      _ -> :ok
    end

    {:ignored, reason}
  end

  defp run_zero_arity(fun) when is_function(fun, 0), do: fun.()
  defp run_zero_arity(_), do: :ok
end
