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

  alias Pincer.Adapters.Tools.Args
  alias Pincer.Core.WorkspaceGuard
  alias Pincer.Ports.{Sandbox, TTS}

  @vision_prompt "Describe this image in detail. Include all text visible in the image."
  @ocr_prompt "Extract ALL text from this image exactly as it appears. Output only the raw text, preserving line breaks."
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
            description: "Page range for 'pdf_extract', e.g. '1-5' or '3'. Default: all pages."
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
    workspace = Args.workspace_root(context)

    llm_client = Application.get_env(:pincer, :media_llm_client, PincerPorts.LLM)
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
    with {:ok, abs_path} <- resolve_path(rel_path, workspace) do
      cond do
        not File.exists?(abs_path) ->
          {:error, "File not found: #{rel_path}"}

        File.dir?(abs_path) ->
          {:error, "Path is a directory: #{rel_path}"}

        true ->
          page_range = Map.get(args, "page_range")
          safe_rel = Path.relative_to(abs_path, Path.expand(workspace))
          extract_pdf_text(safe_rel, workspace, page_range)
      end
    end
  end

  defp run_action("pdf_extract", _args, _ws, _client),
    do: {:error, "Missing required parameter: path"}

  # ---------------------------------------------------------------------------
  # TTS
  # ---------------------------------------------------------------------------

  defp run_action("tts", %{"text" => text} = args, workspace, _client) do
    rel_out = Map.get(args, "output_path", "media/speech.mp3")
    voice = Map.get(args, "voice", @tts_default_voice)
    provider_key = Map.get(args, "provider") || tts_provider()
    tts_client = Application.get_env(:pincer, :media_tts_client, TTS)

    with {:ok, abs_out} <- resolve_path(rel_out, workspace),
         :ok <- File.mkdir_p(Path.dirname(abs_out)),
         {:ok, audio} when is_binary(audio) <-
           tts_client.synthesize_speech(text, voice: voice, provider: provider_key),
         :ok <- File.write(abs_out, audio) do
      {:ok, "Audio saved to #{rel_out} (#{byte_size(audio)} bytes)"}
    else
      {:ok, unexpected} ->
        {:error, "TTS error: unexpected response #{inspect(unexpected)}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, "TTS error: #{inspect(reason)}"}
    end
  end

  defp run_action("tts", _args, _ws, _client),
    do: {:error, "Missing required parameter: text"}

  # ---------------------------------------------------------------------------
  # Transcribe
  # ---------------------------------------------------------------------------

  defp run_action("transcribe", %{"path" => rel_path} = args, workspace, llm_client) do
    with {:ok, abs_path} <- resolve_path(rel_path, workspace) do
      unless File.exists?(abs_path) do
        {:error, "File not found: #{rel_path}"}
      else
        provider = Map.get(args, "provider", "groq_whisper")
        llm_client.transcribe_audio(abs_path, provider: provider)
      end
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
    with {:ok, abs_path} <- resolve_path(rel_path, workspace) do
      cond do
        not File.exists?(abs_path) ->
          {:error, "File not found: #{rel_path}"}

        File.dir?(abs_path) ->
          {:error, "Path is a directory: #{rel_path}"}

        true ->
          mime = mime_from_extension(Path.extname(rel_path))

          case File.read(abs_path) do
            {:ok, data} -> {:ok, Base.encode64(data), mime}
            {:error, reason} -> {:error, "Failed to read file #{rel_path}: #{reason}"}
          end
      end
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

  defp extract_pdf_text(rel_path, workspace, page_range) do
    sandbox_client = Application.get_env(:pincer, :media_sandbox_client, Sandbox)
    expanded_ws = Path.expand(workspace)

    with {:ok, page_args} <- build_page_args(page_range),
         :ok <- validate_pdf_rel_path(rel_path) do
      cmd = Enum.join(["pdftotext"] ++ page_args ++ [rel_path, "-"], " ")

      sandbox_opts = [
        workspace: workspace,
        workspace_path: expanded_ws,
        cwd: expanded_ws,
        restrict_to_workspace: true,
        transport: :os
      ]

      case sandbox_client.run(cmd, sandbox_opts) do
        {:ok, %{output: text, exit_code: 0}} ->
          trimmed = String.trim(to_string(text))

          if trimmed == "" do
            {:ok,
             "(PDF contains no extractable text — may be a scanned image. Use 'ocr' action instead.)"}
          else
            {:ok, trimmed}
          end

        {:ok, %{output: output, exit_code: exit_code}} ->
          if missing_pdftotext_output?(output) do
            {:error, pdftotext_missing_error()}
          else
            {:error,
             "pdftotext exited with #{exit_code}: #{String.slice(to_string(output), 0, 200)}"}
          end

        {:error, reason} when reason in [:enoent, :pdftotext_not_found] ->
          {:error, pdftotext_missing_error()}

        {:error, {:enoent, _}} ->
          {:error, pdftotext_missing_error()}

        {:error, {:command_not_allowed, reason}} ->
          {:error, "PDF extraction blocked: #{reason}"}

        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, reason} ->
          {:error, "PDF extraction failed: #{inspect(reason)}"}
      end
    end
  end

  defp build_page_args(nil), do: {:ok, []}
  defp build_page_args(""), do: {:ok, []}

  defp build_page_args(range) when is_binary(range) do
    case String.trim(range) do
      "" -> {:ok, []}
      trimmed -> parse_page_range(String.split(trimmed, "-"), range)
    end
  end

  defp build_page_args(other),
    do: {:error, "Invalid page_range: #{inspect(other)}. Expected 'N' or 'N-M'."}

  defp parse_page_range([page], raw_range), do: build_page_range(page, page, raw_range)
  defp parse_page_range([first, last], raw_range), do: build_page_range(first, last, raw_range)

  defp parse_page_range(_parts, raw_range),
    do: {:error, "Invalid page_range: #{inspect(raw_range)}. Expected 'N' or 'N-M'."}

  defp build_page_range(first, last, raw_range) do
    f = String.trim(first)
    l = String.trim(last)

    if Regex.match?(~r/^\d+$/, f) and Regex.match?(~r/^\d+$/, l) do
      {:ok, ["-f", f, "-l", l]}
    else
      {:error, "Invalid page_range: #{inspect(raw_range)}. Expected 'N' or 'N-M'."}
    end
  end

  defp validate_pdf_rel_path(rel_path) do
    if String.match?(rel_path, ~r/\s/) do
      {:error, "Invalid PDF path: whitespace is not allowed"}
    else
      :ok
    end
  end

  defp missing_pdftotext_output?(output) when is_binary(output) do
    Regex.match?(~r/pdftotext.*not found/i, output)
  end

  defp missing_pdftotext_output?(_), do: false

  defp pdftotext_missing_error do
    "pdftotext not found. Install poppler-utils: apt install poppler-utils (Debian/Ubuntu) or brew install poppler (macOS)"
  end

  defp resolve_path(rel_path, workspace) do
    WorkspaceGuard.confine_path(rel_path, root: workspace, reject_parent_segments: true)
  end

  defp vision_provider, do: Application.get_env(:pincer, :vision_provider, "google")
  defp tts_provider, do: Application.get_env(:pincer, :tts_provider, "openai")
end
