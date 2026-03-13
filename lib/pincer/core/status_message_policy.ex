defmodule Pincer.Core.StatusMessagePolicy do
  @moduledoc """
  Core policy for aggregated status message delivery across channels.

  Channels remain responsible for transport-specific send/edit operations, while
  this module decides when a status update should noop, create, or edit an
  existing message.
  """

  @type state :: %{
          optional(:status_message_id) => integer() | nil,
          optional(:status_message_text) => String.t() | nil
        }

  @type action :: :noop | {:send, String.t()} | {:edit, integer(), String.t()}

  @spec initial_state() :: state()
  def initial_state do
    %{status_message_id: nil, status_message_text: nil}
  end

  @spec next_action(state(), String.t() | nil) :: action()
  def next_action(state, text) when is_map(state) do
    normalized_text = normalize_text(text)
    current_text = normalize_text(Map.get(state, :status_message_text))

    cond do
      blank?(normalized_text) ->
        :noop

      normalized_text == current_text ->
        :noop

      is_integer(Map.get(state, :status_message_id)) ->
        {:edit, Map.fetch!(state, :status_message_id), normalized_text}

      true ->
        {:send, normalized_text}
    end
  end

  @spec mark_sent(state(), integer(), String.t()) :: state()
  def mark_sent(state, message_id, text) when is_map(state) and is_integer(message_id) do
    state
    |> Map.put(:status_message_id, message_id)
    |> Map.put(:status_message_text, normalize_text(text))
  end

  @spec mark_edited(state(), String.t()) :: state()
  def mark_edited(state, text) when is_map(state) do
    Map.put(state, :status_message_text, normalize_text(text))
  end

  defp normalize_text(nil), do: ""
  defp normalize_text(text), do: to_string(text)

  defp blank?(text), do: String.trim(text) == ""
end
