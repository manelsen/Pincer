defmodule Pincer.Architecture.ChannelInboundTest do
  use ExUnit.Case, async: true

  @all_channel_targets [
    {"telegram",
     ["packages/pincer_telegram/lib/pincer/channels/telegram.ex"] ++
       (Path.wildcard("packages/pincer_telegram/lib/pincer/channels/telegram/*.ex")
        |> Enum.reject(&String.ends_with?(&1, ["/session.ex", "/session_supervisor.ex"])))},
    {"discord", ["packages/pincer_discord/lib/pincer/channels/discord.ex"]},
    {"whatsapp", ["packages/pincer_whatsapp/lib/pincer/channels/whatsapp.ex"]},
    {"dingtalk", ["packages/pincer_dingtalk/lib/pincer/channels/dingtalk.ex"]},
    {"line", ["packages/pincer_line/lib/pincer/channels/line.ex"]},
    {"feishu", ["packages/pincer_feishu/lib/pincer/channels/feishu.ex"]},
    {"slack", ["packages/pincer_slack/lib/pincer/channels/slack.ex"]}
  ]

  @migrated_channel_files [
    "packages/pincer_dingtalk/lib/pincer/channels/dingtalk.ex",
    "packages/pincer_line/lib/pincer/channels/line.ex",
    "packages/pincer_feishu/lib/pincer/channels/feishu.ex",
    "packages/pincer_slack/lib/pincer/channels/slack.ex"
  ]

  test "all 7 channels route inbound events through Shared.Inbound" do
    for {name, files} <- @all_channel_targets do
      combined = Enum.map_join(files, "\n", &File.read!/1)

      assert combined =~ "Inbound.",
             "#{name} must route inbound events through Pincer.Channels.Shared.Inbound"
    end
  end

  test "DingTalk, LINE, Feishu, and Slack delegate session message dispatch to Shared.Inbound" do
    for file <- @migrated_channel_files do
      source = File.read!(file)

      assert source =~ "Inbound.route",
             "#{file} must call Inbound.route/2 for DM policy, command, and message routing"

      refute source =~ "PincerPorts.Session.process_input",
             "#{file} must delegate process_input to Shared.Inbound"
    end
  end
end
