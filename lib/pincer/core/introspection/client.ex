defmodule Pincer.Core.Introspection.Client do
  @moduledoc """
  Wraps LLM calls for the introspection subsystem.

  Uses the introspection-specific provider and model from `config.yaml`,
  falling back to the default LLM provider if not configured.

  ## Configuration

  In `config.yaml`:

      introspection:
        provider: "z_ai"
        model: "glm-4.7"
        max_tokens: 512
        temperature: 0.7

  If the `introspection` section is absent, calls are delegated to the
  default LLM provider without any overrides.
  """

  @doc """
  Sends a chat completion request using the introspection LLM configuration.

  Accepts the same options as `Pincer.Ports.LLM.chat_completion/2`, plus:

    - `:llm_client` — injectable LLM module for testing (default: `Pincer.Ports.LLM`)
  """
  @spec chat_completion([map()], keyword()) :: {:ok, map(), map() | nil} | {:error, term()}
  def chat_completion(messages, extra_opts \\ []) do
    config = introspection_config()
    llm_client = Keyword.get(extra_opts, :llm_client, Pincer.Ports.LLM)

    opts =
      []
      |> maybe_put(:provider, config["provider"])
      |> maybe_put(:model, config["model"])
      |> maybe_put(:max_tokens, config["max_tokens"])
      |> maybe_put(:temperature, config["temperature"])
      |> Keyword.merge(Keyword.delete(extra_opts, :llm_client))

    llm_client.chat_completion(messages, opts)
  end

  defp introspection_config do
    Application.get_env(:pincer, :introspection, %{})
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
