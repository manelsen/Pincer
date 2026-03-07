defmodule Pincer.Channels do
  @moduledoc "Channel Adapters."
  use Boundary,
    deps: [Pincer.Core, Pincer.Infra, Pincer.Ports, Pincer.Utils],
    exports: [
      CLI,
      Discord,
      Slack,
      Telegram,
      Telegram.API,
      Webhook,
      WhatsApp
    ]
end
