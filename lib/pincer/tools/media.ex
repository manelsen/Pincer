defmodule Pincer.Adapters.Tools.Media do
  @moduledoc """
  Media processing tools for Pincer agents: vision, OCR, PDF extraction,
  text-to-speech, and audio transcription.

  ## Actions

  | Action        | Description                                                     |
  |---------------|-----------------------------------------------------------------|
  | `describe`    | Describe or analyze an image using a vision-capable LLM        |
  | `ocr`         | Extract text from an image (vision LLM with OCR prompt)        |
  | `pdf_extract` | Extract text from a PDF file using system tools                 |
  | `tts`         | Convert text to speech and save as an audio file               |
  | `transcribe`  | Transcribe an audio file to text                               |

  ## Prerequisites

  - **vision / ocr**: requires a multimodal LLM provider (e.g. `google`, `openai`)
  - **pdf_extract**: requires `pdftotext` (poppler-utils) installed on the host
  - **tts**: requires an OpenAI-compatible TTS endpoint configured under `:tts_provider`
  - **transcribe**: requires `groq_whisper` or compatible transcription provider

  ## Configuration

      # config.yaml / Application env
      config :pincer, :tts_provider, "openai"        # provider key in :llm_providers
      config :pincer, :vision_provider, "google"     # multimodal provider for describe/ocr

  """
  @behaviour Pincer.Ports.Tool

  require Logger

  @vision_prompt "Describe this image in detail. Include all text visible in the image."
  @ocr_prompt "Extract ALL text from this image exactly as it appears. Output only the raw text, preserving line breaks."
  @tts_url "https://api.openai.com/v1/audio/speech"
  @tts_default_model "tts-1"
  @tts_default_voice "alloy"

  @impl true
  def spec do
    %{
      name: "media",
      description:
        "Processes media files: describe/OCR images, extract PDF text, convert text to speech, transcribe audio.",
      parameters: %{
        type: "object",
        properties: %{
          action: %{
            type: "string",
            description:
              "Action to perform: 'describe', 'ocr', 'pdf_extract', 'tts', or 'transcribe'",
            enum: ["describe", "ocr", "pdf_extract", "tts", "transcribe"]
          },
          path: %{
            type: "string",
            description:
              "Workspace-relative path to the input file (image, PDF, or audio). Required for 'describe', 'ocr', 'pdf_extract', 'transcribe'."
          },
          prompt: %{
            type: "string",
            description:
              "Optional custom instruction for 'describe' (e.g. 'Focus on the chart data')"
          },
          text: %{
            type: "string",
            description: "Text to convert to speech. Required for 'tts'."
          },
          output_path: %{
            type: "string",
            description:
              "Workspace-relative path for the output file. Used by 'tts' (default: 'media/speech.mp3') and 'pdf_extract' with save_to option."
          },
          voice: %{
            type: "string",
            description:
              "Voice for TTS. Options: 'alloy', 'echo', 'fable', 'onyx', 'nova', 'shimmer'. Default: 'alloy'.",
            enum: ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]
          },
          page_range: %{
            type: "string",
            description:
              "Page range for 'pdf_extract', e.g. '1-5' or '3'. Default: all pages."
          },
          provider: %{
            type: "string",
            description:
              "Override the LLM/TTS provider. Default: configured :vision_provider / :tts_provider."
          }
        },
        required: ["action"]
      }
    }
  end

  @impl true
  def execute(%{"action" => action} = args, context \\ %{}) do
    workspace = Map.get(context, "workspace_path") || File.cwd!()
    llm_client = Application.get_env(:pincer, :media_llm_client, Pincer.LLM.Client)
    run_action(action, args, workspace, llm_client)
  end

  # ---------------------------------------------------------------------------
  # Vision — describe image
  # ---------------------------------------------------------------------------

  defp run_action("describe", %{"path" => path} = args, workspace, llm_client) do
    prompt = Map.get(args, "prompt", @vision_prompt)
    provider = Map.get(args, "provider") || vision_provider()

    with {:ok, base64, mime} <- read_image_as_base64(path, workspace) do
      messages = [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => prompt},
            %{"type" => "inline_data", "mime_type" => mime, "data" => base64}
          ]
        }
      ]

      case llm_client.chat_completion(messages, provider: provider) do
        {:ok, %{"content" => text}, _} -> {:ok, text}
        {:error, reason} -> {:error, "Vision failed: #{inspect(reason)}"}
      end
    end
  end

  defp run_action("describe", _args, _ws, _client),
    do: {:error, "Missing required parameter: path"}

  # ---------------------------------------------------------------------------
  # OCR — extract text from image
  # ---------------------------------------------------------------------------

  defp run_action("ocr", %{"path" => path} = args, workspace, llm_client) do
    provider = Map.get(args, "provider") || vision_provider()

    with {:ok, base64, mime} <- read_image_as_base64(path, workspace) do
      messages = [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => @ocr_prompt},
            %{"type" => "inline_data", "mime_type" => mime, "data" => base64}
          ]
        }
      ]

      case llm_client.chat_completion(messages, provider: provider) do
        {:ok, %{"content" => text}, _} -> {:ok, text}
        {:error, reason} -> {:error, "OCR failed: #{inspect(reason)}"}
      end
    end
  end

  defp run_action("ocr", _args, _ws, _client),
    do: {:error, "Missing required parameter: path"}

  # ---------------------------------------------------------------------------
  # PDF extraction
  # ---------------------------------------------------------------------------

  defp run_action("pdf_extract", %{"path" => rel_path} = args, workspace, _client) do
    abs_path = resolve_path(rel_path, workspace)

    unless File.exists?(abs_path) do
      {:error, "File not found: #{rel_path}"}
    else
      page_range = Map.get(args, "page_range")
      extract_pdf_text(abs_path, page_range)
    end
  end

  defp run_action("pdf_extract", _args, _ws, _client),
    do: {:error, "Missing required parameter: path"}

  # ---------------------------------------------------------------------------
  # TTS
  # ---------------------------------------------------------------------------

  defp run_action("tts", %{"text" => text} = args, workspace, _client) do
    rel_out = Map.get(args, "output_path", "media/speech.mp3")
    abs_out = resolve_path(rel_out, workspace)
    File.mkdir_p!(Path.dirname(abs_out))

    voice = Map.get(args, "voice", @tts_default_voice)
    provider_key = Map.get(args, "provider") || tts_provider()

    case resolve_tts_config(provider_key) do
      {:ok, api_key, base_url, model} ->
        body = %{"model" => model, "input" => text, "voice" => voice}
        url = tts_endpoint(base_url)

        case Req.post(url, json: body, auth: {:bearer, api_key}, receive_timeout: 60_000) do
          {:ok, %{status: 200, body: audio}} when is_binary(audio) ->
            File.write!(abs_out, audio)
            {:ok, "Audio saved to #{rel_out} (#{byte_size(audio)} bytes)"}

          {:ok, %{status: status, body: body}} ->
            {:error, "TTS request failed: #{status} — #{inspect(body)}"}

          {:error, reason} ->
            {:error, "TTS request error: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_action("tts", _args, _ws, _client),
    do: {:error, "Missing required parameter: text"}

  # ---------------------------------------------------------------------------
  # Transcribe
  # ---------------------------------------------------------------------------

  defp run_action("transcribe", %{"path" => rel_path} = args, workspace, llm_client) do
    abs_path = resolve_path(rel_path, workspace)

    unless File.exists?(abs_path) do
      {:error, "File not found: #{rel_path}"}
    else
      provider = Map.get(args, "provider", "groq_whisper")
      llm_client.transcribe_audio(abs_path, provider: provider)
    end
  end

  defp run_action("transcribe", _args, _ws, _client),
    do: {:error, "Missing required parameter: path"}

  defp run_action(unknown, _args, _ws, _client),
    do: {:error, "Unknown media action: #{unknown}"}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp read_image_as_base64(rel_path, workspace) do
    abs_path = resolve_path(rel_path, workspace)

    cond do
      not File.exists?(abs_path) ->
        {:error, "File not found: #{rel_path}"}

      File.dir?(abs_path) ->
        {:error, "Path is a directory: #{rel_path}"}

      true ->
        mime = mime_from_extension(Path.extname(rel_path))
        base64 = abs_path |> File.read!() |> Base.encode64()
        {:ok, base64, mime}
    end
  end

  defp mime_from_extension(".jpg"), do: "image/jpeg"
  defp mime_from_extension(".jpeg"), do: "image/jpeg"
  defp mime_from_extension(".png"), do: "image/png"
  defp mime_from_extension(".gif"), do: "image/gif"
  defp mime_from_extension(".webp"), do: "image/webp"
  defp mime_from_extension(".bmp"), do: "image/bmp"
  defp mime_from_extension(".tiff"), do: "image/tiff"
  defp mime_from_extension(".tif"), do: "image/tiff"
  defp mime_from_extension(_), do: "image/jpeg"

  defp extract_pdf_text(abs_path, page_range) do
    pdftotext = System.find_executable("pdftotext")

    if is_nil(pdftotext) do
      {:error,
       "pdftotext not found. Install poppler-utils: apt install poppler-utils (Debian/Ubuntu) or brew install poppler (macOS)"}
    else
      extra_args = build_page_args(page_range)
      args = extra_args ++ [abs_path, "-"]

      case System.cmd(pdftotext, args, stderr_to_stdout: true) do
        {text, 0} ->
          trimmed = String.trim(text)

          if trimmed == "" do
            {:ok, "(PDF contains no extractable text — may be a scanned image. Use 'ocr' action instead.)"}
          else
            {:ok, trimmed}
          end

        {output, exit_code} ->
          {:error, "pdftotext exited with #{exit_code}: #{String.slice(output, 0, 200)}"}
      end
    end
  end

  defp build_page_args(nil), do: []
  defp build_page_args(""), do: []

  defp build_page_args(range) when is_binary(range) do
    case String.split(range, "-") do
      [first, last] ->
        ["-f", String.trim(first), "-l", String.trim(last)]

      [page] ->
        p = String.trim(page)
        ["-f", p, "-l", p]

      _ ->
        []
    end
  end

  defp resolve_tts_config(provider_key) do
    registry = Application.get_env(:pincer, :llm_providers, %{}) || %{}

    case Map.get(registry, provider_key) do
      nil ->
        # Try OpenAI directly from env
        case System.get_env("OPENAI_API_KEY") do
          nil ->
            {:error,
             "TTS provider '#{provider_key}' not configured and OPENAI_API_KEY not set"}

          key ->
            {:ok, key, @tts_url, @tts_default_model}
        end

      config ->
        api_key = config[:api_key] || System.get_env(config[:env_key] || "OPENAI_API_KEY") || ""
        base_url = config[:tts_base_url] || config[:base_url] || @tts_url
        model = config[:tts_model] || @tts_default_model
        {:ok, api_key, base_url, model}
    end
  end

  defp tts_endpoint(base_url) do
    if String.ends_with?(base_url, "/audio/speech") do
      base_url
    else
      # strip trailing path and append TTS endpoint
      base = base_url |> String.trim_trailing("/") |> String.replace(~r{/chat/completions$}, "")
      "#{base}/audio/speech"
    end
  end

  defp resolve_path(rel_path, workspace) do
    if Path.type(rel_path) == :absolute do
      rel_path
    else
      Path.join(workspace, rel_path)
    end
  end

  defp vision_provider, do: Application.get_env(:pincer, :vision_provider, "google")
  defp tts_provider, do: Application.get_env(:pincer, :tts_provider, "openai")
end
