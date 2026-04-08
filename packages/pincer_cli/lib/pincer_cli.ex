defmodule PincerCLI do
  @moduledoc """
  CLI channel adapter for the Pincer AI agent framework.

  ## Installation

  Add to your `mix.exs`:

      {:pincer_cli, "~> 0.1"}

  Then enable in `config.yaml`:

      channels:
        cli:
          enabled: true

  No additional configuration required. The manifest (`priv/pincer_plugin.yaml`)
  is discovered automatically by `Pincer.Plugin.Manifest.discover/0`.
  """
end
