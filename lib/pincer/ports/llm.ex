defmodule Pincer.Ports.LLM do
  @moduledoc "Port for Large Language Model operations."

  @type usage :: %{String.t() => non_neg_integer()}

  @callback chat_completion(list(map()), keyword()) ::
              {:ok, map(), usage() | nil} | {:error, term()}
  @callback stream_completion(list(map()), keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}
  @callback list_providers() :: [%{id: String.t(), name: String.t()}]
  @callback list_models(String.t()) :: [String.t()]
  @callback transcribe_audio(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback provider_config(String.t()) :: map() | nil

  # --- Dispatcher ---

  defp adapter do
    Application.get_env(:pincer, :llm_adapter, Pincer.LLM.Client)
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
