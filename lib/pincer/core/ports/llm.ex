defmodule Pincer.Core.Ports.LLM do
  @moduledoc """
  Port for LLM interactions.

  Decouples the core Executor from the specific LLM client implementation.
  """

  @type message :: map()
  @type options :: keyword()

  @doc """
  Streams a chat completion request.
  """
  @callback stream_completion(messages :: [message()], opts :: options()) :: 
    {:ok, Enumerable.t()} | {:error, any()}
end
