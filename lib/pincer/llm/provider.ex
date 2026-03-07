defmodule Pincer.LLM.Provider do
  @moduledoc """
  Defines the standard behaviour that all LLM Provider Adapters must implement.
  """

  @type message :: %{
          required(:role) => String.t(),
          required(:content) => String.t(),
          optional(:name) => String.t(),
          optional(:tool_calls) => list(map())
        }

  @type tool :: %{
          required(:type) => String.t(),
          required(:function) => %{
            required(:name) => String.t(),
            optional(:description) => String.t(),
            optional(:parameters) => map()
          }
        }

  @type chat_response :: %{
          required(:role) => String.t(),
          optional(:content) => String.t(),
          optional(:tool_calls) => list(map())
        }

  @type chat_result :: {:ok, chat_response()} | {:error, term()}

  @doc """
  Executes a chat completion request natively against the provider's API.
  """
  @callback chat_completion(
              messages :: [message()],
              model :: String.t(),
              config :: map(),
              tools :: [tool()]
            ) ::
              chat_result()

  @doc """
  Executes a streaming chat completion request.
  Returns an Enumerable of message chunks.
  """
  @callback stream_completion(
              messages :: [message()],
              model :: String.t(),
              config :: map(),
              tools :: [tool()]
            ) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc """
  Fetches available models from the provider's API.
  """
  @callback list_models(config :: map()) :: {:ok, [String.t()]} | {:error, any()}

  @doc """
  Transcribes an audio file into text.
  """
  @callback transcribe_audio(file_path :: String.t(), model :: String.t(), config :: map()) ::
              {:ok, String.t()} | {:error, any()}

  @doc """
  Generates a vector embedding for the given text.
  """
  @callback generate_embedding(text :: String.t(), model :: String.t(), config :: map()) ::
              {:ok, [float()]} | {:error, any()}
end
