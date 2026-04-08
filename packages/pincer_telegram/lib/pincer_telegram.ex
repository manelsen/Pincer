defmodule PincerTelegram do
  @moduledoc """
  Telegram channel adapter for the Pincer AI agent framework.

  ## Installation

  Add to your `mix.exs`:

      {:pincer_telegram, "~> 0.1"}

  Then enable in `config.yaml`:

      channels:
        telegram:
          enabled: true
          token_env: "TELEGRAM_BOT_TOKEN"

  The manifest (`priv/pincer_plugin.yaml`) is discovered automatically by
  `Pincer.Plugin.Manifest.discover/0` when this package is installed.
  """
end
