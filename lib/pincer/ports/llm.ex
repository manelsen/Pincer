defmodule Pincer.Ports.LLM do
  @moduledoc """
  Compatibility facade for `PincerPorts.LLM`.

  Existing adapters can still declare this behaviour. New callers and
  adapters should use `PincerPorts.LLM` directly.
  """

  @type usage :: PincerPorts.LLM.usage()

  # Preserve the callback metadata used by existing adapters and mocks.
  @callback chat_completion(list(map()), keyword()) ::
              {:ok, map(), usage() | nil} | {:error, term()}
  @callback stream_completion(list(map()), keyword()) ::
              {:ok, Enumerable.t()} | {:ok, Enumerable.t(), usage() | nil} | {:error, term()}
  @callback list_providers() :: [%{id: String.t(), name: String.t()}]
  @callback list_models(String.t()) :: [String.t()]
  @callback transcribe_audio(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback provider_config(String.t()) :: map() | nil

  @doc "Dispatches a chat completion through the shared LLM port."
  defdelegate chat_completion(history, opts \\ []), to: PincerPorts.LLM
  defdelegate stream_completion(history, opts \\ []), to: PincerPorts.LLM
  defdelegate list_providers(), to: PincerPorts.LLM
  defdelegate list_models(provider_id), to: PincerPorts.LLM
  defdelegate provider_config(provider_id), to: PincerPorts.LLM
  defdelegate generate_embedding(text, opts \\ []), to: PincerPorts.LLM
  defdelegate transcribe_audio(file_path, opts \\ []), to: PincerPorts.LLM
end
