defmodule Pincer.Core.Session.CommandQueue do
  @moduledoc """
  Stateful message queue with three modes: collect, steer, and followup.

  Inspired by ArgentOS's command queue pattern, this replaces the simple
  debounce buffer with a mode-aware queue that determines how incoming
  messages are handled relative to ongoing agent execution.

  ## Modes

    * `:collect` — buffer messages, flush on debounce (agent idle). Default.
    * `:steer` — flush immediately, interrupt current execution.
    * `:followup` — hold message, flush after current turn completes.
  """

  @type mode :: :collect | :steer | :followup
  @type t :: %__MODULE__{mode: mode(), messages: [String.t()]}
  defstruct [:mode, :messages]

  @doc "Create a new empty queue with the given mode (default: :collect)."
  @spec new(mode()) :: t()
  def new(mode \\ :collect), do: %__MODULE__{mode: mode, messages: []}

  @doc """
  Enqueue a message. Returns:
  - `{:ok, queue}` — message buffered, no flush yet
  - `{:flush, [messages], queue}` — messages should be processed immediately
  """
  @spec push(t(), String.t()) :: {:ok, t()} | {:flush, [String.t()], t()}
  def push(%__MODULE__{mode: :steer} = q, message) do
    all = q.messages ++ [message]
    {:flush, all, %__MODULE__{mode: q.mode, messages: []}}
  end

  def push(%__MODULE__{} = q, message) do
    {:ok, %__MODULE__{mode: q.mode, messages: q.messages ++ [message]}}
  end

  @doc "Set the queue mode."
  @spec set_mode(t(), mode()) :: t()
  def set_mode(%__MODULE__{} = q, mode), do: %__MODULE__{q | mode: mode}

  @doc "Drain all pending messages. Returns `{messages, cleared_queue}`."
  @spec drain(t()) :: {[String.t()], t()}
  def drain(%__MODULE__{} = q) do
    {q.messages, %__MODULE__{mode: q.mode, messages: []}}
  end

  @doc "Check if there are pending messages."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{messages: []}), do: false
  def pending?(%__MODULE__{}), do: true

  @doc "Join pending messages with newlines."
  @spec join(t()) :: String.t()
  def join(%__MODULE__{messages: []}), do: ""
  def join(%__MODULE__{messages: msgs}), do: Enum.join(msgs, "\n")
end
