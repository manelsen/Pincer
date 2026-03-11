defmodule Pincer.Ports.MediaUnderstanding do
  @moduledoc "Port for media understanding capabilities."
  use Boundary

  @doc """
  Transcribes audio binary content into text.

  Returns `{:ok, transcription}` on success or `{:error, reason}` on failure.
  """
  @callback transcribe_audio(audio_binary :: binary(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Produces a textual description of an image binary.

  Returns `{:ok, description}` on success or `{:error, reason}` on failure.
  """
  @callback describe_image(image_binary :: binary(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
end
