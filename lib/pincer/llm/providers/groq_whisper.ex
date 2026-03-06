defmodule Pincer.LLM.Providers.GroqWhisper do
  @moduledoc """
  Adapter for Groq Whisper (Audio-to-Text) API.
  """
  @behaviour Pincer.LLM.Provider
  require Logger

  @impl true
  def transcribe_audio(file_path, model, config) do
    api_key = config[:api_key]
    url = "https://api.groq.com/openai/v1/audio/transcriptions"

    # We need to send as multipart form data
    multipart =
      Multipart.new()
      |> Multipart.add_part(Multipart.Part.file_content_field("file", File.read!(file_path), filename: Path.basename(file_path)))
      |> Multipart.add_part(Multipart.Part.text_field("model", model))

    case Req.post(url,
           auth: {:bearer, api_key},
           body: multipart,
           receive_timeout: 60_000
         ) do
      {:ok, %{status: 200, body: %{"text" => text}}} ->
        {:ok, text}

      {:ok, %{status: status, body: body}} ->
        Logger.error("[WHISPER] Failed: #{status} - #{inspect(body)}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Dummy implementations for chat/stream/list to satisfy behavior
  @impl true
  def chat_completion(_m, _mo, _c, _t), do: {:error, :not_implemented}
  @impl true
  def stream_completion(_m, _mo, _c, _t), do: {:error, :not_implemented}
  @impl true
  def list_models(_config), do: {:ok, ["whisper-large-v3", "whisper-large-v3-turbo"]}
end
