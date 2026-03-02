defmodule Pincer.Contracts.ChannelAdapterContractTest do
  use ExUnit.Case, async: true

  @channel_modules [
    Pincer.Channels.Telegram,
    Pincer.Channels.Discord
  ]

  test "channel adapters declare Pincer.Ports.Channel behaviour and required callbacks" do
    Enum.each(@channel_modules, fn channel_module ->
      behaviours = channel_module.module_info(:attributes)[:behaviour] || []

      assert Pincer.Ports.Channel in behaviours or Supervisor in behaviours
      assert function_exported?(channel_module, :start_link, 1)
      assert function_exported?(channel_module, :send_message, 2)
      assert function_exported?(channel_module, :update_message, 3)
      assert function_exported?(channel_module, :register_commands, 0)
    end)
  end
end
