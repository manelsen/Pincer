defmodule Pincer.LLM.Client do
  @moduledoc """
  Unified public facade for LLM operations implementing `PincerPorts.LLM`.

  Delegates routing, retry/failover, model catalog caching, and auxiliary
  capabilities to specialized collaborators:
  - `Pincer.LLM.Failover` (`chat_completion/2`, `stream_completion/2`)
  - `Pincer.LLM.ModelCache` (`list_providers/0`, `provider_config/1`, `list_models/1`)
  - `Pincer.LLM.Capabilities` (`transcribe_audio/2`, `generate_embedding/2`)
  - `Pincer.Core.RetryPolicy` (`parse_retry_after/2`)

  ## Configuration

  Configure providers in your `config/config.exs`:

      config :pincer, :llm_providers, %{
        "openrouter" => %{
          adapter: Pincer.LLM.Providers.OpenAICompat,
          base_url: "https://openrouter.ai/api/v1/chat/completions",
          default_model: "openrouter/free",
          env_key: "OPENROUTER_API_KEY",
          headers: [{"HTTP-Referer", "https://github.com/Pincer/pincer"}, {"X-Title", "Pincer"}]
        }
      }

  ## Examples

      iex> PincerPorts.LLM.chat_completion([
      ...>   %{"role" => "user", "content" => "Hello!"}
      ...> ], provider: "openrouter")
      {:ok, %{"role" => "assistant", "content" => "Hello! How can I help you?"}}
  """

  @behaviour PincerPorts.LLM

  alias Pincer.Core.RetryPolicy
  alias Pincer.LLM.{Capabilities, Failover, ModelCache}

  @type message :: PincerPorts.LLM.Provider.message()
  @type tool :: PincerPorts.LLM.Provider.tool()
  @type chat_result :: PincerPorts.LLM.Provider.chat_result()

  @doc """
  Sends a chat completion request to the configured LLM provider.

  ## Options
  - `:provider` - The string identifier of the provider configured in `:llm_providers`.
    Defaults to the first provider found or "mock".
  - `:model` - The model identifier to use. Defaults to the provider's default model.
  - `:tools` - A list of function tools for the model to call.

  When the retry budget is exhausted, `Pincer.LLM.FailoverDispatch` either
  re-enters on another route or returns the final error.
  """
  @impl true
  @spec chat_completion([message()], keyword()) :: chat_result()
  def chat_completion(messages, opts \\ []) do
    Failover.dispatch(:chat_completion, messages, opts)
  end

  @doc """
  Sends a streaming chat completion request to the configured LLM provider.
  Returns an Enumerable of message chunks.
  """
  @impl true
  @spec stream_completion([message()], keyword()) :: {:ok, Enumerable.t()} | {:error, any()}
  def stream_completion(messages, opts \\ []) do
    Failover.dispatch(:stream_completion, messages, opts)
  end

  @doc """
  Returns a list of all configured LLM providers dynamically from the registry.

  Each provider entry contains:
  - `:id` - The string identifier used in `chat_completion/2` options
  - `:name` - A capitalized human-readable description of the provider
  """
  @impl true
  @spec list_providers() :: [%{id: String.t(), name: String.t()}]
  def list_providers, do: ModelCache.list_providers()

  @doc """
  Returns the raw configuration map for a given provider.
  """
  @impl true
  @spec provider_config(String.t()) :: map() | nil
  def provider_config(provider_id), do: ModelCache.provider_config(provider_id)

  @doc """
  Returns available models for a specific provider from the model-selection
  registry (`config.yaml` `llm` with fallback to `:llm_providers`), using a 1-hour cache.
  """
  @impl true
  @spec list_models(String.t()) :: [String.t()]
  def list_models(provider_id), do: ModelCache.list_models(provider_id)

  @doc """
  Transcribes a local audio file using the configured transcription provider.
  """
  @impl true
  @spec transcribe_audio(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def transcribe_audio(file_path, opts \\ []) do
    Capabilities.transcribe_audio(file_path, opts)
  end

  @doc """
  Generates an embedding vector for `text` using the configured embedding provider.
  """
  @impl true
  @spec generate_embedding(String.t(), keyword()) :: {:ok, [float()]} | {:error, term()}
  def generate_embedding(text, opts \\ []) do
    Capabilities.generate_embedding(text, opts)
  end

  @doc false
  def parse_retry_after(value, now_ms \\ System.system_time(:millisecond))
  def parse_retry_after(value, now_ms), do: RetryPolicy.parse_retry_after(value, now_ms)
end
