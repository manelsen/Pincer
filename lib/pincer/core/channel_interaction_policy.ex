defmodule Pincer.Core.ChannelInteractionPolicy do
  @moduledoc """
  Shared policy for channel interaction payloads (Telegram/Discord).

  Keeps callback/custom IDs within channel limits and provides a strict parser
  for supported actions.
  """

  @type channel :: :telegram | :discord
  @type parse_result ::
          {:ok, {:select_provider, String.t()}}
          | {:ok, {:select_model, String.t(), String.t()}}
          | {:ok, {:page, String.t(), pos_integer()}}
          | {:ok, :back_to_providers}
          | {:ok, :show_menu}
          | {:error, :invalid_payload | :payload_too_large | :invalid_channel}

  @telegram_payload_max_bytes 64
  @discord_payload_max_bytes 100

  @doc """
  Builds a `select_provider` payload for the given channel.
  """
  @spec provider_selector_id(channel(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_payload | :payload_too_large | :invalid_channel}
  def provider_selector_id(channel, provider_id) do
    with :ok <- validate_non_empty(provider_id) do
      build(channel, "select_provider:" <> provider_id)
    end
  end

  @doc """
  Builds a `select_model` payload for the given channel.
  """
  @spec model_selector_id(channel(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_payload | :payload_too_large | :invalid_channel}
  def model_selector_id(channel, provider_id, model) do
    with :ok <- validate_non_empty(provider_id),
         :ok <- validate_non_empty(model) do
      build(channel, "select_model:" <> provider_id <> ":" <> model)
    end
  end

  @doc """
  Returns the payload for the "back to provider list" action.
  """
  @spec back_to_providers_id(channel()) ::
          {:ok, String.t()} | {:error, :payload_too_large | :invalid_channel}
  def back_to_providers_id(channel), do: build(channel, "back_to_providers")

  @doc """
  Returns the payload for the "show menu" action.
  """
  @spec menu_id(channel()) :: {:ok, String.t()} | {:error, :payload_too_large | :invalid_channel}
  def menu_id(channel), do: build(channel, "show_menu")

  @doc """
  Parses and validates a callback/custom ID payload for a given channel.
  """
  @spec parse(channel(), any()) :: parse_result()
  def parse(channel, payload) when is_binary(payload) do
    with {:ok, _limit} <- limit_for(channel),
         :ok <- validate_payload_size(channel, payload) do
      do_parse(payload)
    end
  end

  def parse(_channel, _payload), do: {:error, :invalid_payload}

  defp do_parse("back_to_providers"), do: {:ok, :back_to_providers}
  defp do_parse("show_menu"), do: {:ok, :show_menu}

  defp do_parse("select_provider:" <> provider_id) do
    if provider_id == "" do
      {:error, :invalid_payload}
    else
      {:ok, {:select_provider, provider_id}}
    end
  end

  defp do_parse("select_model:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [provider_id, model] when provider_id != "" and model != "" ->
        {:ok, {:select_model, provider_id, model}}

      _ ->
        {:error, :invalid_payload}
    end
  end

  defp do_parse("page:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [provider_id, page_str] ->
        case Integer.parse(page_str) do
          {page, ""} when page >= 1 -> {:ok, {:page, provider_id, page}}
          _ -> {:error, :invalid_payload}
        end
      _ -> {:error, :invalid_payload}
    end
  end

  defp do_parse(_), do: {:error, :invalid_payload}

  defp build(channel, payload) when is_binary(payload) do
    with {:ok, _limit} <- limit_for(channel),
         :ok <- validate_payload_size(channel, payload) do
      {:ok, payload}
    end
  end

  defp validate_payload_size(channel, payload) do
    {:ok, limit} = limit_for(channel)

    if byte_size(payload) <= limit do
      :ok
    else
      {:error, :payload_too_large}
    end
  end

  defp validate_non_empty(value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :invalid_payload}, else: :ok
  end

  defp validate_non_empty(_), do: {:error, :invalid_payload}

  defp limit_for(:telegram), do: {:ok, @telegram_payload_max_bytes}
  defp limit_for(:discord), do: {:ok, @discord_payload_max_bytes}
  defp limit_for(_), do: {:error, :invalid_channel}
end
