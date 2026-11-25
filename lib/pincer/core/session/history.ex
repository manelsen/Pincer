defmodule Pincer.Core.Session.History do
  @moduledoc """
  Session conversation history management: loading, persistence, pruning,
  reset snapshotting, and user message normalization.
  """

  require Logger

  alias Pincer.Core.{Memory, WorkspaceGuard}
  alias Pincer.Core.Session.Logger, as: SessionLogger
  alias PincerPorts.Structs.IncomingMessage
  alias Pincer.Ports.Storage
  alias PincerPorts.Attachments

  @doc """
  Loads persisted messages for `session_id` and prepends the system prompt.

  Returns `{history, fresh?}` where `fresh?` is `true` when there are no
  previously persisted messages.
  """
  @spec load(String.t(), String.t(), keyword()) :: {[map()], boolean()}
  def load(session_id, system_prompt, opts \\ []) do
    storage = Keyword.get(opts, :storage, Storage)
    persisted = storage.get_messages(session_id)
    system_msg = %{"role" => "system", "content" => system_prompt}
    {[system_msg] ++ persisted, Enum.empty?(persisted)}
  end

  @doc """
  Persists incoming user input to durable storage and appends to the episodic
  session markdown log.
  """
  @spec persist_user_input(String.t(), IncomingMessage.t() | String.t(), String.t(), keyword()) ::
          :ok
  def persist_user_input(session_id, input, workspace_path, opts \\ []) do
    storage = Keyword.get(opts, :storage, Storage)
    session_logger = Keyword.get(opts, :session_logger, SessionLogger)
    text = content_to_text(input)

    _ = storage.save_message(session_id, "user", text)
    _ = session_logger.log(session_id, "user", text, workspace_path: workspace_path)
    :ok
  end

  @doc """
  Persists a non-empty trimmed assistant reply for recovery.
  """
  @spec persist_assistant_response(String.t(), term(), keyword()) :: :ok
  def persist_assistant_response(session_id, response, opts \\ [])

  def persist_assistant_response(session_id, response, opts) when is_binary(response) do
    trimmed = String.trim(response)

    if trimmed != "" do
      storage = Keyword.get(opts, :storage, Storage)
      _ = storage.save_message(session_id, "assistant", trimmed)
    end

    :ok
  end

  def persist_assistant_response(_session_id, _response, _opts), do: :ok

  @doc """
  Converts raw text or an `%IncomingMessage{}` into LLM user history format,
  resolving any `workspace_file_ref` attachments into the workspace first.
  """
  @spec build_user_message(IncomingMessage.t() | String.t(), String.t(), keyword()) :: map()
  def build_user_message(input, workspace_path, opts \\ [])

  def build_user_message(%IncomingMessage{} = input, workspace_path, opts) do
    downloader = Keyword.get(opts, :downloader, &download_workspace_file/3)
    {resolved_input, file_notes} = resolve_workspace_file_refs(input, workspace_path, downloader)
    map_input_to_history(resolved_input, file_notes)
  end

  def build_user_message(input, _workspace_path, _opts) when is_binary(input) do
    %{"role" => "user", "content" => input}
  end

  @doc """
  Prunes history to a sliding window of `:max_messages` non-system messages while
  preserving the leading system prompt and inserting a summary notice when items
  are dropped.
  """
  @spec prune([map()], String.t(), keyword()) :: [map()]
  def prune(history, session_id, opts \\ []) do
    max =
      Keyword.get(opts, :max_messages, Application.get_env(:pincer, :max_history_messages, 100))

    non_system = Enum.reject(history, &(&1["role"] == "system"))

    if length(non_system) <= max do
      history
    else
      system_msg =
        Enum.find(history, &(&1["role"] == "system")) ||
          %{"role" => "system", "content" => ""}

      kept = Enum.take(non_system, -max)
      dropped = length(non_system) - length(kept)

      notice = %{
        "role" => "system",
        "content" =>
          "[Context window pruned: #{dropped} earlier messages removed to stay within the #{max}-message limit. Session: #{session_id}]"
      }

      Logger.debug("[SESSION] #{session_id} history pruned: dropped #{dropped} messages")
      [system_msg, notice | kept]
    end
  end

  @doc """
  Replaces the content of a leading system message in `history` without altering
  subsequent conversation messages.
  """
  @spec swap_system_prompt([map()], String.t()) :: [map()]
  def swap_system_prompt([%{"role" => "system"} | rest], system_prompt) do
    [%{"role" => "system", "content" => system_prompt} | rest]
  end

  def swap_system_prompt(other, _system_prompt), do: other

  @doc """
  Records a compact session reset snapshot via `Pincer.Core.Memory.record_session/2`.
  """
  @spec record_reset_snapshot(String.t(), [map()], keyword()) :: :ok
  def record_reset_snapshot(session_id, history, opts \\ []) do
    memory = Keyword.get(opts, :memory, Memory)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    message_count = history |> Enum.reject(&(&1["role"] == "system")) |> length()

    snapshot_content =
      "session_id=#{session_id} message_count=#{message_count} reset_at=#{DateTime.to_iso8601(now)}"

    case memory.record_session(snapshot_content, session_id: session_id) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.info("[SESSION] reset snapshot skipped: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Extracts plain text from `%IncomingMessage{}`, binary text, or multipart content lists.
  """
  @spec content_to_text(term()) :: String.t()
  def content_to_text(%IncomingMessage{text: text}), do: text || ""
  def content_to_text(content) when is_binary(content), do: content

  def content_to_text(parts) when is_list(parts) do
    Enum.map_join(parts, " ", fn
      %{"text" => text} -> text
      _ -> ""
    end)
  end

  def content_to_text(_other), do: ""

  defp resolve_workspace_file_refs(%IncomingMessage{attachments: []} = input, _ws, _downloader),
    do: {input, []}

  defp resolve_workspace_file_refs(
         %IncomingMessage{attachments: atts} = input,
         workspace_path,
         downloader
       )
       when is_list(atts) do
    {remaining_atts, notes} =
      Enum.reduce(atts, {[], []}, fn att, {kept, downloaded} ->
        if att["type"] == "workspace_file_ref" do
          filename = att["filename"] || "file"
          url = att["url"]

          case downloader.(url, filename, workspace_path) do
            {:ok, rel_path} ->
              {kept, downloaded ++ ["#{filename} saved to workspace at `#{rel_path}`"]}

            {:error, reason} ->
              Logger.warning(
                "[Session] Failed to download workspace file '#{filename}': #{inspect(reason)}"
              )

              {kept, downloaded ++ ["#{filename} (download failed: #{inspect(reason)})"]}
          end
        else
          {kept ++ [att], downloaded}
        end
      end)

    {%{input | attachments: remaining_atts}, notes}
  end

  defp resolve_workspace_file_refs(input, _workspace_path, _downloader), do: {input, []}

  defp map_input_to_history(%IncomingMessage{text: text, attachments: atts}, file_notes)
       when atts in [nil, []] do
    %{"role" => "user", "content" => prepend_file_notes(text, file_notes)}
  end

  defp map_input_to_history(%IncomingMessage{text: text, attachments: atts}, file_notes) do
    full_text = prepend_file_notes(text, file_notes)

    content =
      [%{"type" => "text", "text" => full_text}] ++
        Enum.map(atts, fn a -> %{"type" => "attachment", "attachment" => a} end)

    %{"role" => "user", "content" => content}
  end

  defp prepend_file_notes(text, []), do: text

  defp prepend_file_notes(text, notes) do
    note_block = Enum.map_join(notes, "\n", fn n -> "[File received] #{n}" end)
    if text in ["", nil], do: note_block, else: "#{note_block}\n#{text}"
  end

  defp download_workspace_file(reference, filename, workspace_path) do
    relative_path = Path.join("incoming", filename)

    with {:ok, dest_path} <- WorkspaceGuard.confine_path(relative_path, root: workspace_path),
         {:ok, body} <- Attachments.fetch(reference, :workspace),
         :ok <- File.mkdir_p(Path.dirname(dest_path)),
         :ok <- File.write(dest_path, body) do
      {:ok, Path.relative_to(dest_path, Path.expand(workspace_path))}
    end
  end
end
