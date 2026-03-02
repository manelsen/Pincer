defmodule Pincer.Ports.CapabilityDiscovery do
  @moduledoc """
  Port for capability catalog/discovery in the core.

  This keeps the source of truth for supported capabilities in one domain
  contract, independent from any specific channel or provider adapter.
  """

  @type capability :: %{
          id: String.t(),
          key: atom(),
          name: String.t(),
          owner: atom(),
          status: atom(),
          summary: String.t()
        }

  @callback list_capabilities(context :: map()) :: [capability()]
  @callback find_capability(id :: String.t(), context :: map()) :: {:ok, capability()} | :error
end
