defmodule Pincer.Architecture.ChannelSessionBridgeTest do
  use ExUnit.Case, async: true

  @session_files [
    "packages/pincer_telegram/lib/pincer/channels/telegram/session.ex",
    "packages/pincer_discord/lib/pincer/channels/discord/session.ex",
    "packages/pincer_whatsapp/lib/pincer/channels/whatsapp/session.ex",
    "packages/pincer_dingtalk/lib/pincer/channels/dingtalk/session.ex",
    "packages/pincer_line/lib/pincer/channels/line/session.ex",
    "packages/pincer_feishu/lib/pincer/channels/feishu/session.ex",
    "packages/pincer_slack/lib/pincer/channels/slack/session.ex"
  ]

  @adapter_files [
    "packages/pincer_telegram/lib/pincer/channels/telegram.ex",
    "packages/pincer_discord/lib/pincer/channels/discord.ex",
    "packages/pincer_whatsapp/lib/pincer/channels/whatsapp.ex",
    "packages/pincer_dingtalk/lib/pincer/channels/dingtalk.ex",
    "packages/pincer_line/lib/pincer/channels/line.ex",
    "packages/pincer_feishu/lib/pincer/channels/feishu.ex",
    "packages/pincer_slack/lib/pincer/channels/slack.ex"
  ]

  test "all 7 channel session workers delegate lifecycle to Shared.SessionBridge" do
    for file <- @session_files do
      source = File.read!(file)

      assert source =~ "SessionBridge",
             "#{file} must delegate session lifecycle to Pincer.Channels.Shared.SessionBridge"

      refute source =~ ~r/PubSub\.subscribe\("session:/,
             "#{file} must subscribe to session topics through SessionBridge"
    end
  end

  test "channel adapters delegate session ensure_started to Shared.SessionBridge" do
    for file <- @adapter_files do
      source = File.read!(file)

      assert source =~ "SessionBridge.ensure_started",
             "#{file} must delegate ensure_session_started to SessionBridge.ensure_started"

      refute source =~ "Context.to_start_opts",
             "#{file} must not hand-roll Context.to_start_opts/1 + Registry.lookup"
    end
  end
end
