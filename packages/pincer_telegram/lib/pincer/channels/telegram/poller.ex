defmodule Pincer.Channels.Telegram.Poller do
  @moduledoc """
  Long-polling mechanics, offset persistence, backoff calculation, and
  outbound session delivery routing for Telegram.
  """

  require Logger

  alias Pincer.Channels.Telegram.{Transport, Update}

  @base_poll_interval 1000
  @max_poll_interval 30_000

  @doc """
  Returns the base polling interval in milliseconds.
  """
  @spec base_poll_interval() :: pos_integer()
  def base_poll_interval, do: @base_poll_interval

  @doc """
  Loads the persisted Telegram update offset from disk, returning `0` on missing/invalid files.
  """
  @spec load_offset(String.t()) :: non_neg_integer()
  def load_offset(path) when is_binary(path) do
    case File.read(path) do
      {:ok, raw} ->
        case Integer.parse(String.trim(raw)) do
          {offset, _rest} when offset >= 0 -> offset
          _ -> 0
        end

      {:error, _reason} ->
        0
    end
  end

  @doc """
  Persists the next Telegram update offset to disk.
  """
  @spec persist_offset(String.t(), non_neg_integer()) :: :ok
  def persist_offset(path, offset) when is_binary(path) and is_integer(offset) and offset >= 0 do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, "#{offset}\n") do
      :ok
    else
      {:error, reason} ->
        Logger.warning("[TELEGRAM] Failed to persist offset to #{path}: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Computes the next polling delay in milliseconds using exponential backoff.
  """
  @spec next_poll_interval(non_neg_integer() | term()) :: pos_integer()
  def next_poll_interval(failures) when is_integer(failures) and failures <= 0,
    do: @base_poll_interval

  def next_poll_interval(failures) when is_integer(failures) do
    trunc(min(@base_poll_interval * :math.pow(2, failures), @max_poll_interval))
  end

  def next_poll_interval(_), do: @base_poll_interval

  @doc """
  Fetches and processes Telegram updates, advancing and persisting offset on success
  or incrementing the failure counter and emitting channel policy error telemetry on failure.
  """
  @spec fetch_updates(non_neg_integer(), non_neg_integer(), String.t(), module()) ::
          {non_neg_integer(), non_neg_integer()}
  def fetch_updates(offset, failures, offset_path, api_client \\ Transport.api_client()) do
    case api_client.get_updates(offset: offset, timeout: 5) do
      {:ok, updates} ->
        Enum.each(updates, &Update.process/1)

        new_offset =
          case List.last(updates) do
            %{update_id: update_id} -> update_id + 1
            _ -> offset
          end

        if new_offset != offset do
          persist_offset(offset_path, new_offset)
        end

        {new_offset, 0}

      {:error, reason} ->
        next_failures = failures + 1

        PincerPorts.ChannelPolicy.emit_error(reason, %{
          component: :telegram_poller,
          failures: next_failures
        })

        interval_ms = next_poll_interval(next_failures)

        if PincerPorts.ChannelPolicy.classify(:transient, %{reason: reason}) do
          Logger.warning(
            "Telegram polling error: #{inspect(reason)}. Next interval: #{interval_ms}ms"
          )
        else
          Logger.error(
            "Telegram polling error: #{inspect(reason)}. Next interval: #{interval_ms}ms"
          )
        end

        {offset, next_failures}
    end
  end

  @doc """
  Delivers a `"system:delivery"` PubSub payload if `session_id` targets Telegram.
  """
  @spec deliver_message(String.t(), String.t()) :: {:ok, any()} | {:error, any()} | :ignore
  def deliver_message(session_id, message) when is_binary(session_id) do
    case String.split(session_id, "_", parts: 2) do
      ["telegram", chat_id_str] ->
        chat_id =
          case Integer.parse(chat_id_str) do
            {id, _} -> id
            :error -> chat_id_str
          end

        Transport.send_message(chat_id, message)

      _ ->
        :ignore
    end
  end
end
