defmodule Pincer.Core.AccessPolicy do
  @moduledoc """
  Core DM access policy shared by channel adapters.

  The core decides whether a direct message is allowed. Adapters only provide
  channel metadata and apply the decision.
  """

  alias Pincer.Core.Pairing

  @type channel :: :telegram | :discord
  @type mode :: :open | :allowlist | :disabled | :pairing

  @type allow_result :: {:allow, %{mode: mode()}}
  @type deny_result :: {:deny, %{mode: mode(), reason: atom(), user_message: String.t()}}
  @type result :: allow_result() | deny_result()

  @doc """
  Authorizes a DM sender for a given channel config.

  Config format:

      %{
        "dm_policy" => %{
          "mode" => "open" | "allowlist" | "disabled" | "pairing",
          "allow_from" => ["123", "77*", "*"]
        }
      }

  Unknown or missing modes default to `:open` for backward compatibility.
  """
  @spec authorize_dm(channel(), String.t() | integer(), map()) :: result()
  def authorize_dm(channel, sender_id, config \\ %{}) when is_map(config) do
    policy = dm_policy(config)
    mode = normalize_mode(read_field(policy, "mode"))
    sender = normalize_sender(sender_id)

    case mode do
      :open ->
        {:allow, %{mode: :open}}

      :allowlist ->
        allow_from = normalize_allow_from(read_field(policy, "allow_from"))

        if allowlisted?(sender, allow_from) do
          {:allow, %{mode: :allowlist}}
        else
          {:deny,
           %{
             mode: :allowlist,
             reason: :not_allowlisted,
             user_message: not_allowlisted_message(channel)
           }}
        end

      :disabled ->
        {:deny,
         %{
           mode: :disabled,
           reason: :dm_disabled,
           user_message: disabled_message(channel)
         }}

      :pairing ->
        if Pairing.paired?(channel, sender) do
          {:allow, %{mode: :pairing}}
        else
          {:ok, _pairing} = Pairing.issue_code(channel, sender)

          {:deny,
           %{
             mode: :pairing,
             reason: :pairing_required,
             user_message: pairing_message(channel)
           }}
        end
    end
  end

  defp dm_policy(config) do
    case read_field(config, "dm_policy") do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp normalize_mode(nil), do: :open
  defp normalize_mode(""), do: :open

  defp normalize_mode(mode) do
    normalized =
      mode
      |> to_string()
      |> String.trim()
      |> String.downcase()

    case normalized do
      "open" -> :open
      "allowlist" -> :allowlist
      "disabled" -> :disabled
      "pairing" -> :pairing
      _ -> :open
    end
  end

  defp normalize_allow_from(value) when is_list(value) do
    value
    |> Enum.map(&normalize_sender/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_allow_from(_), do: []

  defp normalize_sender(nil), do: ""

  defp normalize_sender(value) do
    value
    |> to_string()
    |> String.trim()
  end

  defp allowlisted?(_sender, patterns) when not is_list(patterns), do: false
  defp allowlisted?(_sender, []), do: false

  defp allowlisted?(sender, patterns) do
    Enum.any?(patterns, fn pattern ->
      cond do
        pattern == "*" ->
          true

        is_binary(pattern) and String.ends_with?(pattern, "*") ->
          String.starts_with?(sender, String.trim_trailing(pattern, "*"))

        true ->
          sender == pattern
      end
    end)
  end

  defp not_allowlisted_message(:telegram) do
    "Seu usuario nao esta autorizado para conversa direta neste bot. Use /menu apos liberar seu ID."
  end

  defp not_allowlisted_message(:discord) do
    "Seu usuario nao esta autorizado para DM neste bot. Use /menu apos liberar seu ID."
  end

  defp disabled_message(_channel) do
    "Conversas diretas estao desativadas neste canal no momento."
  end

  defp pairing_message(_channel) do
    "Este canal exige pairing para DM. Solicite o codigo ao operador e use /pair <codigo> antes da expiracao."
  end

  defp read_field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp read_field(_, _), do: nil
end
