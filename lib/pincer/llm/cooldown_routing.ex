defmodule Pincer.LLM.CooldownRouting do
  @moduledoc """
  Provider routing around cooling-down endpoints, plus the cooldown bookkeeping
  and diagnostic labels shared by the retry and failover paths.

  Nothing here re-enters `Pincer.LLM.Client`: these are reads of the provider
  registry, writes to the cooldown store, and pure labels.
  """

  require Logger

  alias Pincer.Core.AuthProfiles
  alias Pincer.Core.LLM.CooldownStore
  alias Pincer.Core.Models.Registry, as: ModelRegistry

  @doc """
  Returns the configured provider registry, or an empty map when unset.
  """
  @spec provider_registry() :: map()
  def provider_registry do
    case Application.get_env(:pincer, :llm_providers, %{}) do
      registry when is_map(registry) -> registry
      _ -> %{}
    end
  end

  @doc """
  Overrides the default provider when it is cooling down and another provider
  is available. An explicitly requested provider is always honoured.
  """
  @spec route_around_cooldown(String.t() | nil, map() | term(), boolean()) :: String.t() | nil
  def route_around_cooldown(provider_id, _registry, true), do: provider_id

  def route_around_cooldown(provider_id, _registry, _) when provider_id in [nil, ""],
    do: provider_id

  def route_around_cooldown("mock", _registry, _), do: "mock"

  def route_around_cooldown(provider_id, registry, _explicit?) when is_map(registry) do
    if CooldownStore.cooling_down?(provider_id) do
      candidates =
        registry
        |> ModelRegistry.list_providers()
        |> Enum.map(& &1.id)
        |> CooldownStore.available_providers()

      case candidates do
        [candidate | _] when is_binary(candidate) and candidate != "" ->
          if candidate != provider_id do
            Logger.warning(
              "[CLIENT] Default provider #{provider_id} is cooling down. Routing request to #{candidate}."
            )
          end

          candidate

        _ ->
          provider_id
      end
    else
      provider_id
    end
  end

  def route_around_cooldown(provider_id, _registry, _), do: provider_id

  @doc """
  Clears the cooldown of the provider recorded in `failover_state`.
  """
  @spec clear_provider_cooldown(map() | term()) :: :ok
  def clear_provider_cooldown(failover_state) when is_map(failover_state) do
    case Map.get(failover_state, :current_provider) do
      provider when is_binary(provider) and provider != "" ->
        CooldownStore.clear_provider(provider)

      _ ->
        :ok
    end
  end

  def clear_provider_cooldown(_), do: :ok

  @doc """
  Puts the auth profile that served a failed request into cooldown.
  """
  @spec cooldown_auth_profile(map() | term(), term()) :: :ok | term()
  def cooldown_auth_profile(%{provider_id: provider, profile: profile}, reason)
      when is_binary(provider) and provider != "" and is_binary(profile) and profile != "" do
    AuthProfiles.cooldown_profile(provider, profile, reason)
  end

  def cooldown_auth_profile(_context, _reason), do: :ok

  @doc """
  Clears the cooldown of the auth profile that served a successful request.
  """
  @spec clear_auth_profile_cooldown(map() | term()) :: :ok | term()
  def clear_auth_profile_cooldown(%{provider_id: provider, profile: profile})
      when is_binary(provider) and provider != "" and is_binary(profile) and profile != "" do
    AuthProfiles.clear_profile(provider, profile)
  end

  def clear_auth_profile_cooldown(_context), do: :ok

  @doc """
  Human-readable label for a failure reason, used in logs and runtime status.
  """
  @spec reason_label(term()) :: String.t()
  def reason_label({:http_error, status, _}), do: "HTTP #{status}"
  def reason_label({:http_error, status, _, _}), do: "HTTP #{status}"
  def reason_label({:transport_error, reason}), do: "transport #{inspect(reason)}"
  def reason_label(%Req.TransportError{reason: reason}), do: "transport #{inspect(reason)}"
  def reason_label({:timeout, _}), do: "internal timeout"
  def reason_label(other), do: inspect(other)
end
