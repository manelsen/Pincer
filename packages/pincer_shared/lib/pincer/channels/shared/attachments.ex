defmodule Pincer.Channels.Shared.Attachments do
  @moduledoc """
  Shared attachment sanitization, validation, MIME classification, reference
  building, and inbound/outbound payload helpers across channel adapters.
  """

  alias PincerPorts.Structs.IncomingMessage

  @text_extensions ~w(.md .txt .ex .exs .json .yaml .yml .py .js .ts .csv .xml .toml)
  @allowed_text_content_type_prefixes [
    "text/",
    "application/json",
    "application/x-yaml",
    "application/yaml"
  ]

  @default_multimodal_mime %{
    ".pdf" => "application/pdf",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".webp" => "image/webp",
    ".gif" => "image/gif"
  }

  @doc """
  Sanitizes a filename by replacing unsafe control and markup characters.
  """
  @spec sanitize_filename(term(), String.t()) :: String.t()
  def sanitize_filename(filename, default \\ "attachment")

  def sanitize_filename(filename, default) when is_binary(filename) do
    case String.trim(filename) do
      "" -> default
      clean -> String.replace(clean, ~r/[<>&"'\x00-\x1F]/, "_")
    end
  end

  def sanitize_filename(_, default), do: default

  @doc """
  Normalizes non-negative integer and string byte sizes, returning `0` otherwise.
  """
  @spec normalize_size(term()) :: non_neg_integer()
  def normalize_size(value) when is_integer(value) and value >= 0, do: value

  def normalize_size(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> 0
    end
  end

  def normalize_size(_), do: 0

  @doc """
  Validates that `size` does not exceed `max_bytes`.
  """
  @spec validate_size(term(), pos_integer()) :: :ok | {:error, :too_large}
  def validate_size(size, max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    if normalize_size(size) > max_bytes, do: {:error, :too_large}, else: :ok
  end

  @doc """
  Returns `true` when `filename_or_ext` has a supported inline text extension.
  """
  @spec text_extension?(String.t()) :: boolean()
  def text_extension?(filename_or_ext) when is_binary(filename_or_ext) do
    ext =
      if String.starts_with?(filename_or_ext, ".") do
        String.downcase(filename_or_ext)
      else
        filename_or_ext |> Path.extname() |> String.downcase()
      end

    ext in @text_extensions
  end

  @doc """
  Returns `true` when an HTTP `content-type` header matches an allowed inline
  text prefix.
  """
  @spec valid_text_content_type?(String.t()) :: boolean()
  def valid_text_content_type?(content_type) when is_binary(content_type) do
    normalized = String.downcase(content_type)
    Enum.any?(@allowed_text_content_type_prefixes, &String.starts_with?(normalized, &1))
  end

  def valid_text_content_type?(_), do: false

  @doc """
  Looks up the canonical multimodal MIME type for an extension, if known.
  """
  @spec multimodal_mime(String.t(), map()) :: String.t() | nil
  def multimodal_mime(ext, extra_mimes \\ %{}) when is_binary(ext) and is_map(extra_mimes) do
    normalized = String.downcase(ext)
    Map.get(Map.merge(@default_multimodal_mime, extra_mimes), normalized)
  end

  @doc """
  Returns `true` when `ext` or `mime` represents a multimodal attachment.
  """
  @spec multimodal_extension?(String.t(), String.t(), keyword()) :: boolean()
  def multimodal_extension?(ext, mime \\ "", opts \\ [])
      when is_binary(ext) and is_binary(mime) and is_list(opts) do
    extra_mimes = Keyword.get(opts, :extra_mimes, %{})
    allow_text_mime? = Keyword.get(opts, :allow_text_mime, false)

    not is_nil(multimodal_mime(ext, extra_mimes)) or
      (allow_text_mime? and String.starts_with?(mime, "text/"))
  end

  @doc """
  Resolves an attachment MIME type from a declared type or filename extension,
  defaulting to `"application/octet-stream"`.
  """
  @spec resolve_mime(term(), String.t(), keyword()) :: String.t()
  def resolve_mime(declared_mime, filename, opts \\ [])
      when is_binary(filename) and is_list(opts) do
    extra_mimes = Keyword.get(opts, :extra_mimes, %{})
    ext = filename |> Path.extname() |> String.downcase()

    cond do
      is_binary(declared_mime) and String.trim(declared_mime) != "" ->
        String.trim(declared_mime)

      mime = multimodal_mime(ext, extra_mimes) ->
        mime

      true ->
        "application/octet-stream"
    end
  end

  @doc """
  Builds a lazy attachment reference map (`"attachment_ref"` or `"workspace_file_ref"`).
  """
  @spec build_ref(String.t(), String.t(), String.t(), term(), keyword()) :: map()
  def build_ref(url, filename, mime_type, size, opts \\ [])
      when is_binary(url) and is_binary(mime_type) and is_list(opts) do
    type = Keyword.get(opts, :type, "attachment_ref")

    %{
      "type" => type,
      "url" => url,
      "mime_type" => mime_type,
      "filename" => sanitize_filename(filename),
      "size" => normalize_size(size)
    }
  end

  @doc """
  Formats standardized metadata text for an attachment.
  """
  @spec format_meta(String.t(), term(), String.t()) :: String.t()
  def format_meta(filename, size, suffix \\ "") do
    "[Attachment: #{filename} (#{normalize_size(size)} bytes)]#{suffix}"
  end

  @doc """
  Appends attachment metadata to an accumulated text string.
  """
  @spec append_meta(String.t(), String.t(), term(), String.t(), keyword()) :: String.t()
  def append_meta(text_acc, filename, size, suffix \\ "", opts \\ [])
      when is_binary(text_acc) and is_list(opts) do
    separator = Keyword.get(opts, :separator, "\n")
    meta = format_meta(filename, size, suffix)

    [text_acc, meta]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(separator)
  end

  @doc """
  Wraps downloaded inline attachment text with standardized file delimiters.
  """
  @spec format_inline_file(String.t(), String.t()) :: String.t()
  def format_inline_file(filename, content) when is_binary(content) do
    safe_name = sanitize_filename(filename)
    "--- Content of #{safe_name} ---\n#{content}\n--- End of File ---"
  end

  @doc """
  Selects the photo map with the largest `file_size` from a Telegram photo list.
  """
  @spec largest_photo(term()) :: map() | nil
  def largest_photo(photos) when is_list(photos) do
    photos
    |> Enum.filter(&is_map/1)
    |> Enum.max_by(
      fn photo ->
        photo
        |> then(&(Map.get(&1, :file_size) || Map.get(&1, "file_size")))
        |> normalize_size()
      end,
      fn -> nil end
    )
  end

  def largest_photo(_), do: nil

  @doc """
  Combines message base text, extracted attachment text, and lazy attachment
  references into `:empty`, `{:ok, text}`, or `{:ok, parts}`.
  """
  @spec combine_content(String.t() | nil, String.t() | nil, [map()]) ::
          :empty | {:ok, String.t() | [map()]}
  def combine_content(base_text, attachment_text, refs) when is_list(refs) do
    text_content =
      [base_text || "", attachment_text || ""]
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

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

  @doc """
  Converts combined text or part lists into `PincerPorts.Structs.IncomingMessage`.
  """
  @spec to_incoming_message(String.t(), String.t() | [map()], keyword()) :: IncomingMessage.t()
  def to_incoming_message(session_id, text, _opts \\ [])

  def to_incoming_message(session_id, text, _opts)
      when is_binary(session_id) and is_binary(text) do
    IncomingMessage.new(session_id, text)
  end

  def to_incoming_message(session_id, parts, opts)
      when is_binary(session_id) and is_list(parts) and is_list(opts) do
    allowed_types = Keyword.get(opts, :attachment_types, ["attachment_ref", "workspace_file_ref"])
    {text_parts, att_parts} = Enum.split_with(parts, &(&1["type"] == "text"))
    text = Enum.map_join(text_parts, "\n", & &1["text"])

    atts =
      att_parts
      |> Enum.map(fn
        %{"type" => type} = part ->
          if type in allowed_types, do: part, else: nil

        %{"attachment" => nested} when is_map(nested) ->
          nested

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    IncomingMessage.new(session_id, text: text, attachments: atts)
  end

  @doc """
  Processes a list of inbound attachment maps (`%{filename, size, url}`) into
  `{inline_text, attachment_refs}`.

  Accepts `:download_text` (`(attachment -> String.t())`) for inline text files
  and `:extra_mimes` for additional multimodal extensions.
  """
  @spec process_list(term(), keyword()) :: {String.t(), [map()]}
  def process_list(attachments, opts \\ [])

  def process_list(attachments, opts)
      when is_list(attachments) and attachments != [] and is_list(opts) do
    download_text = Keyword.get(opts, :download_text, fn _att -> "" end)
    extra_mimes = Keyword.get(opts, :extra_mimes, %{})

    Enum.reduce(attachments, {"", []}, fn attachment, {texts, refs} ->
      filename = Map.get(attachment, :filename) || Map.get(attachment, "filename") || "attachment"
      size = Map.get(attachment, :size) || Map.get(attachment, "size")
      url = Map.get(attachment, :url) || Map.get(attachment, "url")
      ext = filename |> Path.extname() |> String.downcase()
      meta = format_meta(filename, size)

      cond do
        text_extension?(ext) ->
          content = download_text.(attachment)
          {texts <> "\n\n" <> meta <> "\n" <> content, refs}

        mime = multimodal_mime(ext, extra_mimes) ->
          ref = build_ref(url, filename, mime, size)
          {texts, refs ++ [ref]}

        true ->
          {texts <> "\n\n" <> meta <> " (unsupported format)", refs}
      end
    end)
  end

  def process_list(_attachments, _opts), do: {"", []}

  @doc """
  Extracts large fenced code blocks from outbound text into file payloads
  (`%{name: filename, body: code}`), replacing them with attachment notices.
  """
  @spec extract_large_code_blocks(String.t(), [map()], keyword()) :: {String.t(), [map()]}
  def extract_large_code_blocks(text, existing_files \\ [], opts \\ [])
      when is_binary(text) and is_list(existing_files) and is_list(opts) do
    min_text_len = Keyword.get(opts, :min_text_length, 1500)
    min_code_bytes = Keyword.get(opts, :min_code_bytes, 1000)

    if String.length(text) > min_text_len and String.contains?(text, "```") do
      case Regex.run(~r/```(\w+)?\n([\s\S]*?)\n```/i, text) do
        [full_block, lang, code] when byte_size(code) > min_code_bytes ->
          ext = if lang in [nil, ""], do: "txt", else: lang
          filename = "code_block.#{ext}"
          file = %{name: filename, body: code}

          remaining_text =
            String.replace(
              text,
              full_block,
              "\n📎 *[Content sent in attachment: #{filename}]*"
            )

          extract_large_code_blocks(remaining_text, existing_files ++ [file], opts)

        _ ->
          {text, existing_files}
      end
    else
      {text, existing_files}
    end
  end
end
