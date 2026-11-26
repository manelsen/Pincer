defmodule Pincer.Ports.TTS do
  @moduledoc """
  Port for text-to-speech synthesis.

  Decouples tool adapters from concrete LLM provider HTTP requests and
  credential/endpoint resolution.
  """

  @callback synthesize_speech(text :: String.t(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}

  @doc """
  Synthesizes `text` into audio bytes using the configured `:tts_adapter`.
  """
  @spec synthesize_speech(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def synthesize_speech(text, opts \\ []) when is_binary(text) and is_list(opts) do
    adapter().synthesize_speech(text, opts)
  end

  defp adapter do
    case Application.fetch_env(:pincer, :tts_adapter) do
      {:ok, mod} when is_atom(mod) and not is_nil(mod) and not is_boolean(mod) ->
        mod

      {:ok, invalid} ->
        raise ArgumentError,
              "invalid :tts_adapter configuration for :pincer: #{inspect(invalid)}"

      :error ->
        raise ArgumentError,
              "missing :tts_adapter configuration for :pincer (configure config :pincer, :tts_adapter, ...)"
    end
  end
end
