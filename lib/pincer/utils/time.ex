defmodule Pincer.Utils.Time do
  @moduledoc """
  Shared time helpers with explicit units.
  """

  @spec monotonic_ms() :: integer()
  def monotonic_ms, do: System.monotonic_time(:millisecond)

  @spec system_ms() :: integer()
  def system_ms, do: System.system_time(:millisecond)
end
