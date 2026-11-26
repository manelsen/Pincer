defmodule Pincer.Channels.Telegram.Media do
  @moduledoc """
  Inbound Telegram attachment detection, resolution, and audio transcription.
  """

  require Logger

  alias Pincer.Channels.Shared.Attachments
  alias Pincer.Channels.Telegram.Transport

  @max_attachment_bytes 104_857_600
  @groq_max_audio_bytes 25_165_824
  @extra_multimodal_mimes %{
    ".log" => "text/plain",
    ".txt" => "text/plain"
  }

  @doc """
  Returns `true` when the Telegram message carries a document, photo, or audio/video payload.
  """
  @spec has_supported_attachments?(map()) :: boolean()
  def has_supported_attachments?(message) when is_map(message) do
    has_document?(message) or has_photo?(message) or has_audio?(message)
  end

  def has_supported_attachments?(_), do: false

  @doc """
  Extracts inbound text, captions, attachment references, and audio transcriptions
  from a Telegram message payload.
  """
  @spec prepare_input_content(map(), module()) :: {:ok, String.t() | [map()]} | :empty
  def prepare_input_content(message, api_client \\ Transport.api_client())

  def prepare_input_content(message, api_client) when is_map(message) do
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
    {rev_texts, rev_refs} =
      {[], []}
      |> maybe_collect_document(message, api_client)
      |> maybe_collect_photo(message, api_client)
      |> maybe_collect_audio(message, api_client)

    text =
      rev_texts
      |> Enum.reverse()
      |> Enum.join("\n")
      |> String.trim()

    {text, Enum.reverse(rev_refs)}
  end

  defp maybe_collect_audio({rev_texts, rev_refs}, message, api_client) do
    audio_obj =
      map_value(message, :voice) ||
        map_value(message, :audio) ||
        map_value(message, :video) ||
        map_value(message, :video_note)

    case audio_obj do
      obj when is_map(obj) ->
        file_id = map_value(obj, :file_id)

        ext =
          if map_value(message, :video) || map_value(message, :video_note),
            do: ".mp4",
            else: ".mp3"

        case handle_audio_transcription(file_id, ext, api_client) do
          {:ok, transcribed_text} ->
            chat_id = map_value(map_value(message, :chat), :id)
            if chat_id, do: Transport.send_message(chat_id, "🎤 <i>\"#{transcribed_text}\"</i>")
            {[transcribed_text | rev_texts], rev_refs}

          _ ->
            {["[Media content - transcription failed]" | rev_texts], rev_refs}
        end

      _ ->
        {rev_texts, rev_refs}
    end
  end

  defp handle_audio_transcription(file_id, ext, api_client) do
    with {:ok, file_path} <- resolve_file_path(api_client, file_id),
         token <- Application.get_env(:telegex, :token),
         url <- "https://api.telegram.org/file/bot#{token}/#{file_path}",
         {:ok, %{status: 200, body: body}} when is_binary(body) <-
           Req.get(url, receive_timeout: 300_000) do
      transcribe_audio_body(body, file_id, ext)
    else
      {:ok, _response} -> {:error, :download_failed}
      _ -> {:error, :transcription_failed}
    end
  end

  defp transcribe_audio_body(body, file_id, ext) do
    temp_file = "/tmp/pincer_media_#{file_id}#{ext}"

    case File.write(temp_file, body) do
      {:error, reason} ->
        Logger.error("[TELEGRAM] Failed to write temp audio file: #{inspect(reason)}")
        {:error, :write_failed}

      :ok ->
        try do
          if byte_size(body) > @groq_max_audio_bytes do
            Logger.info(
              "[TELEGRAM] Media file too large for Groq (#{byte_size(body)} bytes). Splitting..."
            )

            process_large_audio(temp_file, file_id)
          else
            PincerPorts.LLM.transcribe_audio(temp_file, provider: "groq_whisper")
          end
        after
          File.rm(temp_file)
        end
    end
  end

  defp process_large_audio(input_file, file_id) do
    chunk_prefix = "/tmp/pincer_chunk_#{file_id}"

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
        chunks = Path.wildcard("#{chunk_prefix}_*.mp3") |> Enum.sort()
        Logger.info("[TELEGRAM] Audio split into #{length(chunks)} chunks.")

        texts =
          Enum.map(chunks, fn chunk ->
            case PincerPorts.LLM.transcribe_audio(chunk, provider: "groq_whisper") do
              {:ok, text} -> text
              _ -> "[Transcription of chunk failed]"
            end
          end)

        Enum.each(chunks, &File.rm/1)
        {:ok, Enum.join(texts, " ")}

      {error, _} ->
        Logger.error("[TELEGRAM] ffmpeg split failed: #{inspect(error)}")
        PincerPorts.LLM.transcribe_audio(input_file, provider: "groq_whisper")
    end
  end

  defp maybe_collect_document({rev_texts, rev_refs}, message, api_client) do
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
            meta = Attachments.format_meta(filename, size, " (arquivo grande demais)")
            {[meta | rev_texts], rev_refs}

          not multimodal? ->
            collect_document_ref(
              {rev_texts, rev_refs},
              document,
              filename,
              size,
              mime,
              api_client,
              "workspace_file_ref",
              "non-multimodal document"
            )

          true ->
            collect_document_ref(
              {rev_texts, rev_refs},
              document,
              filename,
              size,
              mime,
              api_client,
              "attachment_ref",
              "document attachment"
            )
        end

      _ ->
        {rev_texts, rev_refs}
    end
  end

  defp collect_document_ref(
         {rev_texts, rev_refs},
         document,
         filename,
         size,
         mime,
         api_client,
         ref_type,
         log_label
       ) do
    case build_attachment_ref(document, filename, size, mime, api_client, ref_type) do
      {:ok, ref} ->
        {rev_texts, [ref | rev_refs]}

      {:error, reason} ->
        Logger.warning(
          "[TELEGRAM] Failed to resolve #{log_label} '#{filename}': #{inspect(reason)}"
        )

        meta = Attachments.format_meta(filename, size, " (erro ao resolver arquivo)")
        {[meta | rev_texts], rev_refs}
    end
  end

  defp maybe_collect_photo({rev_texts, rev_refs}, message, api_client) do
    case map_value(message, :photo) do
      photos when is_list(photos) and photos != [] ->
        with photo when is_map(photo) <- Attachments.largest_photo(photos),
             size <- Attachments.normalize_size(map_value(photo, :file_size)),
             unique_id <-
               map_value(photo, :file_unique_id) || map_value(photo, :file_id) || "photo",
             filename <- Attachments.sanitize_filename("photo_#{unique_id}.jpg"),
             {:ok, ref} <-
               build_attachment_ref(photo, filename, size, "image/jpeg", api_client) do
          {rev_texts, [ref | rev_refs]}
        else
          nil ->
            {rev_texts, rev_refs}

          {:error, reason} ->
            Logger.warning("[TELEGRAM] Failed to resolve photo attachment: #{inspect(reason)}")
            {rev_texts, rev_refs}
        end

      _ ->
        {rev_texts, rev_refs}
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
    case normalize_binary(value) do
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

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_, _), do: nil
end
