defmodule Pincer.Channels.Shared do
  @moduledoc "Shared helpers used by Pincer's channel packages."

  use Boundary, deps: [], exports: [Inbound, Text, TokenCache, WebhookVerifier]
end
