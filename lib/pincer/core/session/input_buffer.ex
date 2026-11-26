defmodule Pincer.Core.Session.InputBuffer do
  @moduledoc """
  Manages debounced user input buffering and flush scheduling for a session.
  """

  alias Pincer.Core.Session.History, as: SessionHistory
  alias Pincer.Infra.PubSub

  @default_debounce_ms 1200

  @doc """
  Appends `input_text` to the session input buffer, cancels any active debounce
  timer, notifies the channel if the session is currently `:working`, and
  schedules a new `:flush_input` timer.
  """
  @spec enqueue(map(), term(), keyword()) :: map()
  def enqueue(state, input_text, opts \\ []) do
    debounce_ms = Keyword.get(opts, :debounce_ms, @default_debounce_ms)
    timer_cancel_fn = Keyword.get(opts, :timer_cancel_fn, &Process.cancel_timer/1)

    timer_send_fn =
      Keyword.get(opts, :timer_send_fn, fn ms -> Process.send_after(self(), :flush_input, ms) end)

    publish_fn =
      Keyword.get(opts, :publish_fn, fn sid, event ->
        PubSub.broadcast("session:#{sid}", event)
      end)

    if state.status == :working do
      publish_fn.(
        state.session_id,
        {:agent_status, "⏳ Mensagem recebida. Vou processar após concluir o passo atual..."}
      )
    end

    if state.debounce_timer, do: timer_cancel_fn.(state.debounce_timer)
    new_buffer = state.input_buffer ++ [input_text]
    new_timer = timer_send_fn.(debounce_ms)

    %{state | input_buffer: new_buffer, debounce_timer: new_timer}
  end

  @doc """
  Combines all buffered input entries into a single newline-delimited string
  and resets the buffer and timer state.
  """
  @spec flush(map()) :: {String.t(), map()}
  def flush(state) do
    combined_input = Enum.map_join(state.input_buffer, "\n", &SessionHistory.content_to_text/1)
    {combined_input, %{state | input_buffer: [], debounce_timer: nil}}
  end

  @doc """
  Cancels any active debounce timer and clears queued buffered inputs.
  """
  @spec clear(map(), keyword()) :: map()
  def clear(state, opts \\ []) do
    timer_cancel_fn = Keyword.get(opts, :timer_cancel_fn, &Process.cancel_timer/1)
    if state.debounce_timer, do: timer_cancel_fn.(state.debounce_timer)
    %{state | input_buffer: [], debounce_timer: nil}
  end
end
