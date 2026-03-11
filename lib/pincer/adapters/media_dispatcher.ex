defmodule Pincer.Adapters.MediaDispatcher do
  @moduledoc """
  Dispatcher for media understanding operations.

  Routes transcription requests to `Pincer.LLM.Providers.GroqWhisper` and
  image description requests to the provider configured via
  `Application.get_env(:pincer, :image_provider, "google")`.
  """
  use Boundary

  @behaviour Pincer.Ports.MediaUnderstanding

  @doc """
  Transcribes audio binary content to text using Groq Whisper.

  The binary is written to a temporary file, passed to the transcription
  adapter, and the temp file is cleaned up afterwards.
  """
  @impl true
  def transcribe_audio(audio_binary, opts \\ []) when is_binary(audio_binary) do
    Pincer.Ports.LLM.transcribe_audio(
      audio_binary,
      Keyword.put_new(opts, :provider, "groq_whisper")
    )
  end

  @doc """
  Produces a textual description of an image binary using the configured
  image provider (default: `"google"`).

  The image must be a JPEG, PNG, GIF, or WebP binary. The provider is
  read from `Application.get_env(:pincer, :image_provider, "google")`.
  """
  @impl true
  def describe_image(image_binary, opts \\ []) when is_binary(image_binary) do
    provider = Application.get_env(:pincer, :image_provider, "google")
    mime_type = Keyword.get(opts, :mime_type, "image/jpeg")
    prompt = Keyword.get(opts, :prompt, "Describe this image in detail.")

    base64_data = Base.encode64(image_binary)

    messages = [
      %{
        "role" => "user",
        "content" => [
          %{"type" => "inline_data", "mime_type" => mime_type, "data" => base64_data},
          %{"type" => "text", "text" => prompt}
        ]
      }
    ]

    case Pincer.Ports.LLM.chat_completion(messages, Keyword.put(opts, :provider, provider)) do
      {:ok, %{"content" => content}, _usage} -> {:ok, content}
      {:ok, %{"content" => content}} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end
end
