defmodule Pincer.Core.StatusDelivery do
  @moduledoc """
  Orchestrates status-message delivery through transport callbacks.

  `StatusMessagePolicy` remains the pure decision-maker; this module only
  coordinates send/edit side effects and updates channel state accordingly.
  """

  alias Pincer.Core.StatusMessagePolicy

  @spec deliver(map(), String.t() | nil, keyword()) :: map()
  def deliver(state, text, transport) when is_map(state) do
    case StatusMessagePolicy.next_action(state, text) do
      :noop ->
        state

      {:send, text} ->
        case transport[:send].(text) do
          {:ok, message_id} when is_integer(message_id) ->
            StatusMessagePolicy.mark_sent(state, message_id, text)

          {:ok, %{message_id: message_id}} when is_integer(message_id) ->
            StatusMessagePolicy.mark_sent(state, message_id, text)

          {:ok, %{id: message_id}} when is_integer(message_id) ->
            StatusMessagePolicy.mark_sent(state, message_id, text)

          _ ->
            state
        end

      {:edit, message_id, text} ->
        case transport[:edit].(message_id, text) do
          :ok ->
            StatusMessagePolicy.mark_edited(state, text)

          {:ok, _payload} ->
            StatusMessagePolicy.mark_edited(state, text)

          _ ->
            case transport[:send].(text) do
              {:ok, new_message_id} when is_integer(new_message_id) ->
                StatusMessagePolicy.mark_sent(state, new_message_id, text)

              {:ok, %{message_id: new_message_id}} when is_integer(new_message_id) ->
                StatusMessagePolicy.mark_sent(state, new_message_id, text)

              {:ok, %{id: new_message_id}} when is_integer(new_message_id) ->
                StatusMessagePolicy.mark_sent(state, new_message_id, text)

              _ ->
                state
            end
        end
    end
  end
end
