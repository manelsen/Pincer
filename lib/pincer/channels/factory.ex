defmodule Pincer.Channels.Factory do
  @moduledoc """
  Factory module for dynamic channel instantiation based on configuration.

  The Factory reads channel definitions from `config.yaml` and produces child
  specs suitable for `Pincer.Channels.Supervisor`. It supports:

  - YAML-based channel enablement
  - Runtime channel whitelisting (e.g., via Mix tasks)
  - Dynamic adapter module resolution

  ## Configuration Format

  Channels are defined in `config.yaml` under the `channels` key:

      channels:
        telegram:
          enabled: true
          adapter: "Pincer.Channels.Telegram"
          token_env: "TELEGRAM_BOT_TOKEN"
        cli:
          enabled: true
          adapter: "Pincer.Channels.CLI"
        discord:
          enabled: false
          adapter: "Pincer.Channels.Discord"

  ## Filtering Logic

  Channels are included if:

  1. `enabled: true` in YAML, AND
  2. Either no whitelist exists, OR the channel name is in the whitelist

  The whitelist can be set at runtime:

      Application.put_env(:pincer, :enabled_channels, ["telegram"])

  This is useful for Mix tasks that start only specific channels:

      # Start only CLI channel
      mix pincer.cli --only cli

  ## Child Spec Format

  Each enabled channel produces a tuple `{module, config}` where:

  - `module` - The adapter module atom (e.g., `Pincer.Channels.Telegram`)
  - `config` - The channel's configuration map from YAML

  This tuple format is compatible with Supervisor child specs when the
  module implements `child_spec/1` or `start_link/1`.

  ## Examples

      # Get all enabled channels
      children = Pincer.Channels.Factory.create_channel_specs()
      # => [{Pincer.Channels.Telegram, %{"enabled" => true, ...}}, ...]

      # Use in Supervisor
      Supervisor.init(children, strategy: :one_for_one)

      # Override with whitelist
      Application.put_env(:pincer, :enabled_channels, ["cli"])
      Pincer.Channels.Factory.create_channel_specs()
      # => [{Pincer.Channels.CLI, %{"enabled" => true, ...}}]

  ## See Also

  - `Pincer.Channels.Supervisor` - Uses Factory to start channels
  - `Pincer.Ports.Channel` - Behaviour that channels implement
  - `Pincer.Infra.Config` - Configuration loading from YAML
  """

  require Logger

  @doc """
  Creates child specs for all enabled channels.

  Reads channel configuration and filters based on enablement status and
  optional whitelist. Returns a list of `{module, config}` tuples suitable
  for Supervisor.init/2.

  ## Parameters

    - `config` - Optional channel configuration map. If not provided, reads
                from `Pincer.Infra.Config.get(:channels, %{})`

  ## Returns

  A list of `{module, config}` tuples for each enabled channel.

  ## Examples

      iex> Pincer.Channels.Factory.create_channel_specs(%{})
      []

      # With custom config
      iex> config = %{"cli" => %{"enabled" => true, "adapter" => "Pincer.Channels.CLI"}}
      iex> Pincer.Channels.Factory.create_channel_specs(config)
      [{Pincer.Channels.CLI, %{"enabled" => true, "adapter" => "Pincer.Channels.CLI"}}]
  """
  @spec create_channel_specs(config :: map() | nil) :: [{module(), map()}]
  def create_channel_specs(config \\ nil) do
    config = case config do
      nil -> Pincer.Infra.Config.get(:channels, %{})
      %{"channels" => c} -> c
      c -> c
    end

    whitelist = Application.get_env(:pincer, :enabled_channels)

    config
    |> Enum.filter(fn {name, cfg} ->
      enabled_in_yaml = cfg["enabled"] == true

      if whitelist do
        Enum.member?(whitelist, name)
      else
        enabled_in_yaml
      end
    end)
    |> Enum.map(fn {name, cfg} ->
      module_name = cfg["adapter"]
      module = Module.concat([module_name])

      Logger.info("Enabling Channel: #{name} (#{module_name})")

      {module, cfg}
    end)
  end
end
