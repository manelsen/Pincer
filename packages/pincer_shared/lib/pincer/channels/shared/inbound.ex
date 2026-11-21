defmodule Pincer.Channels.Shared.Inbound do
  @moduledoc """
  Channel-agnostic inbound message pipeline.

  Every chat adapter (Telegram, Discord, WhatsApp, ...) walks the same decision
  tree before handing a message to the session:

      1. is it a slash command?            -> :command
      2. does it resolve to a UX shortcut? -> :command
      3. is a project wizard collecting?   -> :project
      4. otherwise                         -> :message

  The wording of the branches, their order and the attachment handling are easy
  to get subtly wrong per adapter, so this module owns the decision and the
  adapter owns the actions. It deliberately has **no dependency on
  `Pincer.Core`**: the caller passes the few operations that need Core as
  functions, which keeps `pincer_shared` publishable on its own.

  ## Example

      Shared.Inbound.dispatch(inbound,
        resolve_shortcut: &UX.resolve_shortcut/1,
        continue_project: fn sid, text, opts -> ProjectRouter.continue_if_collecting(sid, text, opts) end
      )

  ## Callbacks: the `inbound` map

    * `:text` - the raw text, or `nil` when the payload is attachment-only
    * `:has_attachments` - boolean
    * `:session_id` - resolved session id for the sender
    * `:on_command` - `fn text -> result end`, invoked for slash commands and
      shortcuts with the command string
    * `:on_project_response` - `fn response, session_id -> any end`, invoked when
      a project wizard consumed the message
    * `:on_message` - `fn text_or_content -> result end`, invoked for a normal
      message
    * `:on_ignored` - optional `fn reason -> any end`, invoked when nothing runs
  """

  @type result ::
          {:command, term()}
          | {:shortcut, term()}
          | {:project, term()}
          | {:message, term()}
          | {:ignored, atom()}

  @type inbound :: %{
          required(:text) => String.t() | nil,
          required(:has_attachments) => boolean(),
          required(:session_id) => String.t() | nil,
          required(:on_command) => (String.t() -> term()),
          required(:on_message) => (term() -> term()),
          optional(:on_project_response) => (term(), String.t() -> term()),
          optional(:on_ignored) => (atom() -> term())
        }

  @type opts :: [
          resolve_shortcut: (String.t() -> {:ok, String.t()} | :error),
          continue_project: (String.t(), String.t(), keyword() ->
                               {:handled, term()} | :not_handled)
        ]

  @doc """
  Runs the inbound decision tree.

  Command and shortcut branches win over project collection, which in turn wins
  over normal message handling. Attachment-only payloads skip the text
  branches entirely.
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

  defp ignore(inbound, reason) do
    case Map.get(inbound, :on_ignored) do
      fun when is_function(fun, 1) -> fun.(reason)
      _ -> :ok
    end

    {:ignored, reason}
  end
end
