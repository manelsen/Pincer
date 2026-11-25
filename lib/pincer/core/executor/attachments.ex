defmodule Pincer.Core.Executor.Attachments do
  @moduledoc """
  Lazy attachment resolution and download helpers for executor prompt history.
  """

  alias Pincer.Utils.MapHelpers

  @max_inline_bytes Application.compile_env(:pincer, :max_inline_bytes, 6_291_456)
  @max_text_preview_chars 32_768

  @doc """
  Fetches attachment bytes through the port and encodes them for prompt history.
  """
  @spec default_fetch(String.t()) :: {:ok, String.t()} | {:error, term()}
  def default_fetch(reference) do
    with {:ok, bytes} <- PincerPorts.Attachments.fetch(reference, {:inline, @max_inline_bytes}) do
      {:ok, Base.encode64(bytes)}
    end
  end

  @doc """
  Resolves `attachment_ref` parts across `history` using the explicit `file_fetcher`.
  """
  @spec resolve_history([map()], map(), (String.t() -> {:ok, String.t()} | {:error, term()})) ::
          [map()]
  def resolve_history(history, provider_config, file_fetcher)
      when is_list(history) and is_function(file_fetcher, 1) do
    provider = provider_config || %{}
    Enum.map(history, &resolve_msg_attachments(&1, provider, file_fetcher))
  end

  defp resolve_msg_attachments(%{"content" => content} = msg, provider, file_fetcher)
       when is_list(content) do
    Map.put(msg, "content", Enum.map(content, &resolve_part(&1, provider, file_fetcher)))
  end

  defp resolve_msg_attachments(msg, _provider, _file_fetcher), do: msg

  defp resolve_part(%{"type" => "attachment_ref"} = ref, provider, file_fetcher) do
    url = ref["url"] || ""
    mime = ref["mime_type"] || "application/octet-stream"
    filename = ref["filename"] || "attachment"
    size = ref["size"] || 0

    cond do
      size > @max_inline_bytes ->
        %{
          "type" => "text",
          "text" => "[#{filename} exceeds inline limit (#{div(size, 1_048_576)} MB) — not loaded]"
        }

      String.starts_with?(mime, "text/") ->
        fetch_text_part(url, filename, file_fetcher)

      MapHelpers.read_field(provider, :supports_files) ->
        fetch_inline_part(url, mime, filename, file_fetcher)

      true ->
        %{
          "type" => "text",
          "text" => "[Provider does not support attachments: #{filename} (#{mime})]"
        }
    end
  end

  defp resolve_part(part, _provider, _file_fetcher), do: part

  defp fetch_text_part(url, filename, file_fetcher) do
    case file_fetcher.(url) do
      {:ok, b64} ->
        text = b64 |> Base.decode64!() |> String.slice(0, @max_text_preview_chars)
        %{"type" => "text", "text" => "Content of #{filename}:\n#{text}"}

      {:error, reason} ->
        %{"type" => "text", "text" => "[Failed to download #{filename}: #{inspect(reason)}]"}
    end
  end

  defp fetch_inline_part(url, mime, filename, file_fetcher) do
    case file_fetcher.(url) do
      {:ok, b64} ->
        %{"type" => "inline_data", "mime_type" => mime, "data" => b64}

      {:error, reason} ->
        %{"type" => "text", "text" => "[Failed to download #{filename}: #{inspect(reason)}]"}
    end
  end
end
