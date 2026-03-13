defmodule Pincer.Core.StreamDelivery do
  @moduledoc """
  Coordinates streaming preview/final delivery through transport callbacks.

  The core owns the preview/final semantics through `StreamingPolicy`; channels
  only provide `send` and `edit` functions plus any transport-specific options.
  """

  alias Pincer.Core.StreamingPolicy

  @type transport :: [
          send: (String.t() -> any()),
          edit: (integer(), String.t() -> any())
        ]

  @spec handle_partial(map(), String.t(), integer(), transport(), keyword()) :: map()
  def handle_partial(state, token, now_ms, transport, opts \\ []) when is_map(state) do
    {stream_state, action} =
      StreamingPolicy.on_partial(StreamingPolicy.extract(state), token, now_ms, opts)

    case action do
      {:render_preview, preview_text} ->
        message_id =
          upsert_preview(
            stream_state.message_id,
            preview_text,
            transport[:send],
            transport[:edit]
          )

        StreamingPolicy.assign(
          state,
          StreamingPolicy.mark_rendered(stream_state, message_id, now_ms)
        )

      :noop ->
        StreamingPolicy.assign(state, stream_state)
    end
  end

  @spec handle_final(map(), String.t(), transport()) :: map()
  def handle_final(state, text, transport) when is_map(state) do
    {stream_state, action} = StreamingPolicy.on_final(StreamingPolicy.extract(state), text)

    case action do
      :noop ->
        state

      {:send_final, text} ->
        _ = transport[:send].(text)
        StreamingPolicy.assign(state, stream_state)

      {:edit_final, message_id, text} ->
        case transport[:edit].(message_id, text) do
          :ok ->
            StreamingPolicy.assign(state, stream_state)

          {:error, _reason} ->
            _ = transport[:send].(text)
            StreamingPolicy.assign(state, stream_state)

          _other ->
            _ = transport[:send].(text)
            StreamingPolicy.assign(state, stream_state)
        end
    end
  end

  defp upsert_preview(nil, text, send_fun, _edit_fun) do
    normalize_message_id(send_fun.(text))
  end

  defp upsert_preview(message_id, text, send_fun, edit_fun) do
    case edit_fun.(message_id, text) do
      :ok -> message_id
      {:ok, _} -> message_id
      _other -> normalize_message_id(send_fun.(text))
    end
  end

  defp normalize_message_id({:ok, message_id}) when is_integer(message_id), do: message_id

  defp normalize_message_id({:ok, %{message_id: message_id}}) when is_integer(message_id),
    do: message_id

  defp normalize_message_id({:ok, %{id: message_id}}) when is_integer(message_id), do: message_id
  defp normalize_message_id(_other), do: nil
end
