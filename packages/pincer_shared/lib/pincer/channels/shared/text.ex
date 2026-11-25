defmodule Pincer.Channels.Shared.Text do
  @moduledoc """
  Backwards-compatible facade for reasoning cleanup and HTML formatting.

  Delegates to `Pincer.Channels.Shared.Formatting`.
  """

  alias Pincer.Channels.Shared.Formatting

  @doc """
  Removes user-invisible reasoning blocks from a response while preserving
  the externally visible answer text.
  """
  defdelegate strip_reasoning(text), to: Formatting

  @doc """
  Formats reasoning blocks for HTML-capable channels while preserving the final answer.
  """
  defdelegate format_reasoning_html(text), to: Formatting
end
