defmodule Pincer.Core.Structs.IncomingMessage do
  @moduledoc """
  Agnostic structure for incoming messages from any channel.
  This is the entry point of the Anti-Corruption Layer (ACL).
  """

  defstruct [
    :session_id,
    :text,
    :attachments,
    :metadata,
    :timestamp
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          text: String.t() | nil,
          attachments: [map()] | nil,
          metadata: map() | nil,
          timestamp: DateTime.t()
        }

  def new(session_id, text_or_opts) do
    case text_or_opts do
      text when is_binary(text) ->
        %__MODULE__{
          session_id: session_id,
          text: text,
          attachments: [],
          metadata: %{},
          timestamp: DateTime.utc_now()
        }

      opts when is_list(opts) ->
        %__MODULE__{
          session_id: session_id,
          text: Keyword.get(opts, :text),
          attachments: Keyword.get(opts, :attachments, []),
          metadata: Keyword.get(opts, :metadata, %{}),
          timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now())
        }
    end
  end
end
