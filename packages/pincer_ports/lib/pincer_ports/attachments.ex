defmodule PincerPorts.Attachments do
  @moduledoc "Retrieves bytes for opaque attachment references emitted by channels."

  @type attachment_ref :: String.t()
  @type mode :: :workspace | {:inline, pos_integer()}
  @type result :: {:ok, binary()} | {:error, term()}

  @callback fetch(attachment_ref(), mode()) :: result()

  @doc "Fetches attachment bytes through the host's configured adapter."
  @spec fetch(attachment_ref(), mode()) :: result()
  def fetch(reference, mode) do
    adapter = Application.fetch_env!(:pincer, :attachment_adapter)
    adapter.fetch(reference, mode)
  end
end
