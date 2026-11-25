defmodule Pincer.Channels.Shared do
  @moduledoc "Shared helpers used by Pincer's channel packages."

  use Boundary,
    deps: [PincerPorts],
    exports: [
      Attachments,
      Chunking,
      Formatting,
      Inbound,
      Pairing,
      ProjectBridge,
      SessionBridge,
      Text,
      TokenCache,
      WebhookVerifier
    ]
end
