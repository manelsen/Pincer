defmodule Pincer.Core.StreamingPolicy do
  @moduledoc """
  Shared streaming preview/finalization policy for channel session workers.

  Goals:
  - keep preview cursor (`▌`) only during token streaming;
  - finalize in-place when a preview message already exists;
  - avoid duplicate final sends.
  """

  @default_debounce_ms 1000

  @type state :: %{
          message_id: integer() | nil,
          buffer: String.t(),
          last_update: integer()
        }

  @type partial_action :: :noop | {:render_preview, String.t()}

  @type final_action ::
          :noop | {:send_final, String.t()} | {:edit_final, integer(), String.t()}

  @spec initial_state() :: state()
  def initial_state do
    %{message_id: nil, buffer: "", last_update: 0}
  end

  @spec on_partial(state(), String.t(), integer(), keyword()) :: {state(), partial_action()}
  def on_partial(state, token, now_ms, opts \\ []) do
    debounce_ms = Keyword.get(opts, :debounce_ms, @default_debounce_ms)
    token = stringify(token)

    new_state = %{state | buffer: state.buffer <> token}

    cond do
      new_state.buffer == "" ->
        {new_state, :noop}

      is_nil(state.message_id) ->
        {new_state, {:render_preview, preview_text(new_state.buffer)}}

      now_ms - state.last_update >= debounce_ms ->
        {new_state, {:render_preview, preview_text(new_state.buffer)}}

      true ->
        {new_state, :noop}
    end
  end

  @spec mark_rendered(state(), integer() | nil, integer()) :: state()
  def mark_rendered(state, message_id, now_ms) do
    %{state | message_id: message_id, last_update: now_ms}
  end

  @spec on_final(state(), String.t()) :: {state(), final_action()}
  def on_final(state, final_text) do
    text = normalize_final_text(final_text, state.buffer)
    reset_state = initial_state()

    cond do
      text == "" ->
        {reset_state, :noop}

      is_integer(state.message_id) ->
        {reset_state, {:edit_final, state.message_id, text}}

      true ->
        {reset_state, {:send_final, text}}
    end
  end

  defp preview_text(text), do: normalize_text(text) <> " ▌"

  defp normalize_final_text(final_text, fallback_buffer) do
    final = stringify(final_text)

    if blank?(final) do
      stringify(fallback_buffer)
    else
      final
    end
  end

  defp normalize_text(nil), do: ""
  defp normalize_text(text), do: stringify(text)

  defp stringify(nil), do: ""
  defp stringify(text), do: to_string(text)
  defp blank?(text), do: String.trim(text) == ""
end
