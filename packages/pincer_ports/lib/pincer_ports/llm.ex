defmodule PincerPorts.LLM do
  @moduledoc """
  Behaviour and dispatcher for application-level LLM operations.

  The host configures an adapter with `config :pincer, :llm_adapter, MyAdapter`.
  """

  @type usage :: map()

  @callback chat_completion(list(map()), keyword()) ::
              {:ok, map(), usage() | nil} | {:error, term()}
  @callback stream_completion(list(map()), keyword()) ::
              {:ok, Enumerable.t()} | {:ok, Enumerable.t(), usage() | nil} | {:error, term()}
  @callback list_providers() :: [%{id: String.t(), name: String.t()}]
  @callback list_models(String.t()) :: [String.t()]
  @callback generate_embedding(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  @callback transcribe_audio(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback provider_config(String.t()) :: map() | nil

  @doc "Requests a complete response for the chat history."
  def chat_completion(history, opts \\ []), do: adapter().chat_completion(history, opts)

  @doc "Requests a streamed response for the chat history."
  def stream_completion(history, opts \\ []), do: adapter().stream_completion(history, opts)

  @doc "Lists the available providers."
  def list_providers, do: adapter().list_providers()

  @doc "Lists the available models for a provider."
  def list_models(provider_id), do: adapter().list_models(provider_id)

  @doc "Returns the configuration for a provider."
  def provider_config(provider_id), do: adapter().provider_config(provider_id)

  @doc "Requests an embedding for the given text."
  def generate_embedding(text, opts \\ []), do: adapter().generate_embedding(text, opts)

  @doc "Requests a transcription of a local audio file."
  def transcribe_audio(file_path, opts \\ []), do: adapter().transcribe_audio(file_path, opts)

  defp adapter do
    case Application.fetch_env(:pincer, :llm_adapter) do
      {:ok, mod} when is_atom(mod) and not is_nil(mod) and not is_boolean(mod) ->
        mod

      {:ok, invalid} ->
        raise ArgumentError,
              "invalid :llm_adapter configuration for :pincer: #{inspect(invalid)}"

      :error ->
        raise ArgumentError,
              "missing :llm_adapter configuration for :pincer (configure config :pincer, :llm_adapter, ...)"
    end
  end
end
