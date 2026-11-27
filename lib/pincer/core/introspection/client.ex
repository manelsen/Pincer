defmodule Pincer.Core.Introspection.Client do
  @moduledoc """
  Wraps LLM calls for the introspection subsystem and enforces local-inference
  locality when active sessions run against a local provider.

  Uses the introspection-specific provider and model from `config.yaml`,
  falling back to the default LLM provider if not configured. When an active
  session uses a local provider (such as `ollama`), introspection and lesson
  extraction stay local instead of sending execution traces to external cloud
  providers.

  ## Configuration

  In `config.yaml`:

      introspection:
        provider: "groq"
        model: "llama-3.1-8b-instant"
        max_tokens: 512
        temperature: 0.7
        locality: "follow_session" # optional: "follow_session" | "local_only"
  """

  alias Pincer.Utils.MapHelpers

  @default_local_providers MapSet.new(["ollama", "local", "lmstudio", "llamacpp", "vllm"])

  @doc """
  Returns `true` if `provider` refers to a local inference backend.
  """
  @spec local_provider?(String.t() | atom() | nil, map() | nil) :: boolean()
  def local_provider?(provider, config \\ nil)

  def local_provider?(nil, _config), do: false

  def local_provider?(provider, config) do
    normalized = normalize_provider(provider)

    if is_nil(normalized) do
      false
    else
      configured =
        (config || introspection_config())
        |> MapHelpers.read_field(:local_providers)
        |> List.wrap()
        |> Enum.map(&normalize_provider/1)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      MapSet.member?(MapSet.union(@default_local_providers, configured), normalized)
    end
  end

  @doc """
  Computes the effective introspection target (`%{provider, model, locality, blocked?}`)
  given an optional `session_model_override`.
  """
  @spec effective_target(map() | nil, map() | nil) :: %{
          provider: String.t() | nil,
          model: String.t() | nil,
          locality:
            :local_session | :follow_session | :local | :configured | :local_only | :default,
          blocked?: boolean()
        }
  def effective_target(session_model_override \\ nil, config \\ nil) do
    cfg = config || introspection_config()
    config_provider = normalize_provider(MapHelpers.read_field(cfg, :provider))
    config_model = normalize_non_empty(MapHelpers.read_field(cfg, :model))
    locality_policy = normalize_locality(MapHelpers.read_field(cfg, :locality))

    {session_provider, session_model} = extract_override(session_model_override)
    config_local? = local_provider?(config_provider, cfg)
    session_local? = local_provider?(session_provider, cfg)

    cond do
      session_local? and not config_local? ->
        %{
          provider: session_provider,
          model: session_model,
          locality: :local_session,
          blocked?: false
        }

      locality_policy == :follow_session and not is_nil(session_provider) ->
        %{
          provider: session_provider,
          model: session_model || config_model,
          locality: :follow_session,
          blocked?: false
        }

      locality_policy == :local_only ->
        effective_provider = config_provider || normalize_provider(default_llm_provider())

        if local_provider?(effective_provider, cfg) do
          %{
            provider: effective_provider,
            model: config_model,
            locality: :local,
            blocked?: false
          }
        else
          %{
            provider: effective_provider,
            model: config_model,
            locality: :local_only,
            blocked?: true
          }
        end

      is_binary(config_provider) ->
        %{
          provider: config_provider,
          model: config_model,
          locality: if(config_local?, do: :local, else: :configured),
          blocked?: false
        }

      true ->
        fallback = normalize_provider(default_llm_provider())

        %{
          provider: fallback,
          model: nil,
          locality: if(local_provider?(fallback, cfg), do: :local, else: :default),
          blocked?: false
        }
    end
  end

  @doc """
  Sends a chat completion request using the introspection LLM configuration.

  Accepts the same options as `Pincer.Ports.LLM.chat_completion/2`, plus:

    - `:llm_client` — injectable LLM module for testing (default: `Pincer.Ports.LLM`)
    - `:session_model_override` — session model override map used to preserve
      local-inference locality
  """
  @spec chat_completion([map()], keyword()) :: {:ok, map(), map() | nil} | {:error, term()}
  def chat_completion(messages, extra_opts \\ []) do
    config = introspection_config()
    llm_client = Keyword.get(extra_opts, :llm_client, Pincer.Ports.LLM)
    {session_override, clean_extra_opts} = Keyword.pop(extra_opts, :session_model_override)
    clean_extra_opts = Keyword.delete(clean_extra_opts, :llm_client)

    target = effective_target(session_override, config)

    if target.blocked? do
      {:error, :non_local_introspection_blocked}
    else
      configured_provider? =
        is_binary(normalize_provider(MapHelpers.read_field(config, :provider))) or
          target.locality in [:local_session, :follow_session]

      opts =
        []
        |> maybe_put(:provider, if(configured_provider?, do: target.provider, else: nil))
        |> maybe_put(:model, if(configured_provider?, do: target.model, else: nil))
        |> maybe_put(:max_tokens, MapHelpers.read_field(config, :max_tokens))
        |> maybe_put(:temperature, MapHelpers.read_field(config, :temperature))
        |> Keyword.merge(clean_extra_opts)

      llm_client.chat_completion(messages, opts)
    end
  end

  defp introspection_config do
    Application.get_env(:pincer, :introspection, %{})
  end

  defp default_llm_provider do
    Application.get_env(:pincer, :default_llm_provider)
  end

  defp extract_override(override) when is_map(override) do
    provider = normalize_provider(MapHelpers.read_field(override, :provider))
    model = normalize_non_empty(MapHelpers.read_field(override, :model))
    {provider, model}
  end

  defp extract_override(_), do: {nil, nil}

  defp normalize_locality(nil), do: :default

  defp normalize_locality(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "follow_session" -> :follow_session
      "local_only" -> :local_only
      _ -> :default
    end
  end

  defp normalize_provider(nil), do: nil

  defp normalize_provider(value) when is_atom(value) do
    value |> Atom.to_string() |> normalize_provider()
  end

  defp normalize_provider(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      "nil" -> nil
      normalized -> normalized
    end
  end

  defp normalize_provider(_), do: nil

  defp normalize_non_empty(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_non_empty(_), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
