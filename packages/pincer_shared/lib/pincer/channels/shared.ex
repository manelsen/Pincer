defmodule Pincer.Channels.Shared do
  @moduledoc "Shared helpers used by Pincer's channel packages."

  use Boundary,
    deps: [PincerPorts],
    exports: [Inbound, SessionBridge, Text, TokenCache, WebhookVerifier]
end
