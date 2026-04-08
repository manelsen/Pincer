defmodule Pincer.Channels do
  @moduledoc "Channel Adapters."
  use Boundary,
    deps: [Pincer.Core, Pincer.Infra, Pincer.Plugin, Pincer.Ports, Pincer.Utils],
    exports: [
      Discord,
      Slack,
      Telegram,
      Telegram.API,
      Webhook,
      WhatsApp
    ]
end
