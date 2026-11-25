defmodule Pincer.Ports.LLM do
  @moduledoc "Port for Large Language Model operations."

  @type usage :: Pincer.Core.Structs.Usage.t()

  @callback chat_completion(list(map()), keyword()) ::
              {:ok, map(), usage() | nil} | {:error, term()}
  @callback stream_completion(list(map()), keyword()) ::
              {:ok, Enumerable.t()} | {:ok, Enumerable.t(), usage() | nil} | {:error, term()}
  @callback list_providers() :: [%{id: String.t(), name: String.t()}]
  @callback list_models(String.t()) :: [String.t()]
  @callback transcribe_audio(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback provider_config(String.t()) :: map() | nil

  # --- Dispatcher ---

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

  def chat_completion(history, opts \\ []), do: adapter().chat_completion(history, opts)
  def stream_completion(history, opts \\ []), do: adapter().stream_completion(history, opts)
  def list_providers, do: adapter().list_providers()
  def list_models(provider_id), do: adapter().list_models(provider_id)
  def provider_config(provider_id), do: adapter().provider_config(provider_id)
  def generate_embedding(text, opts \\ []), do: adapter().generate_embedding(text, opts)

  def transcribe_audio(file_path, opts \\ []) do
    adapter().transcribe_audio(file_path, opts)
  end
end
