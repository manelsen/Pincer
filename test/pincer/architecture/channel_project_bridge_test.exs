defmodule Pincer.Architecture.ChannelProjectBridgeTest do
  use ExUnit.Case, async: true

  @session_files [
    "packages/pincer_telegram/lib/pincer/channels/telegram/session.ex",
    "packages/pincer_discord/lib/pincer/channels/discord/session.ex",
    "packages/pincer_whatsapp/lib/pincer/channels/whatsapp/session.ex"
  ]

  @adapter_files [
    "packages/pincer_telegram/lib/pincer/channels/telegram.ex",
    "packages/pincer_discord/lib/pincer/channels/discord.ex",
    "packages/pincer_whatsapp/lib/pincer/channels/whatsapp.ex"
  ]

  test "Telegram, Discord, and WhatsApp sessions delegate project callbacks to Shared.ProjectBridge" do
    for file <- @session_files do
      source = File.read!(file)

      assert source =~ "ProjectBridge",
             "#{file} must delegate project callbacks to Pincer.Channels.Shared.ProjectBridge"

      refute source =~ "PincerPorts.Project.on_agent_response",
             "#{file} must route on_agent_response through ProjectBridge"

      refute source =~ "PincerPorts.Project.on_agent_error",
             "#{file} must route on_agent_error through ProjectBridge"
    end
  end

  test "Telegram, Discord, and WhatsApp adapters delegate kickoff and continue to Shared.ProjectBridge" do
    for file <- @adapter_files do
      source = File.read!(file)

      assert source =~ "ProjectBridge.kickoff",
             "#{file} must delegate kickoff to ProjectBridge.kickoff"

      assert source =~ "ProjectBridge.continue",
             "#{file} must delegate continue_project to ProjectBridge.continue"

      refute source =~ "PincerPorts.Project.kickoff",
             "#{file} must not call PincerPorts.Project.kickoff directly"

      refute source =~ "PincerPorts.Project.continue_if_collecting",
             "#{file} must not call PincerPorts.Project.continue_if_collecting directly"
    end
  end
end
