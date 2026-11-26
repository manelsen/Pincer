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

  @adapter_targets [
    {"telegram",
     ["packages/pincer_telegram/lib/pincer/channels/telegram.ex"] ++
       Path.wildcard("packages/pincer_telegram/lib/pincer/channels/telegram/*.ex")},
    {"discord", ["packages/pincer_discord/lib/pincer/channels/discord.ex"]},
    {"whatsapp", ["packages/pincer_whatsapp/lib/pincer/channels/whatsapp.ex"]},
    {"dingtalk", ["packages/pincer_dingtalk/lib/pincer/channels/dingtalk.ex"]},
    {"line", ["packages/pincer_line/lib/pincer/channels/line.ex"]},
    {"feishu", ["packages/pincer_feishu/lib/pincer/channels/feishu.ex"]},
    {"slack", ["packages/pincer_slack/lib/pincer/channels/slack.ex"]}
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
    for {name, files} <- @adapter_targets do
      combined = Enum.map_join(files, "\n", &File.read!/1)

      assert combined =~ "SessionBridge.ensure_started",
             "#{name} must delegate ensure_session_started to SessionBridge.ensure_started"

      for file <- files do
        source = File.read!(file)

        refute source =~ "Context.to_start_opts",
               "#{file} must not hand-roll Context.to_start_opts/1 + Registry.lookup"
      end
    end
  end
end
