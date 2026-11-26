defmodule Pincer.Architecture.ChannelSharedHelpersTest do
  use ExUnit.Case, async: true

  defp telegram_adapter_files do
    ["packages/pincer_telegram/lib/pincer/channels/telegram.ex"] ++
      (Path.wildcard("packages/pincer_telegram/lib/pincer/channels/telegram/*.ex")
       |> Enum.reject(&String.ends_with?(&1, ["/session.ex", "/session_supervisor.ex"])))
  end

  defp assert_delegates!(targets, required_substring, required_msg, forbidden_checks) do
    for {name, files} <- targets do
      combined = Enum.map_join(files, "\n", &File.read!/1)

      assert combined =~ required_substring,
             "#{name} #{required_msg}"

      for file <- files, {pattern, message} <- forbidden_checks do
        refute File.read!(file) =~ pattern,
               "#{file} #{message}"
      end
    end
  end

  test "channels delegate chunking and streaming buffer flushes to Shared.Chunking" do
    assert_delegates!(
      [
        {"telegram", telegram_adapter_files()},
        {"discord", ["packages/pincer_discord/lib/pincer/channels/discord.ex"]},
        {"whatsapp", ["packages/pincer_whatsapp/lib/pincer/channels/whatsapp.ex"]},
        {"line_session", ["packages/pincer_line/lib/pincer/channels/line/session.ex"]}
      ],
      "Chunking",
      "must delegate chunking to Pincer.Channels.Shared.Chunking",
      [
        {"defp smart_chunk_text", "must not define a local smart_chunk_text/2 copy"},
        {"defp find_last_newline_within",
         "must not define a local find_last_newline_within/2 copy"},
        {"defp split_outbound_chunks", "must not define a local split_outbound_chunks/1 copy"},
        {"@sentence_boundary", "must delegate stream boundary detection to Shared.Chunking"}
      ]
    )
  end

  test "channels delegate formatting helpers to Shared.Formatting" do
    assert_delegates!(
      [
        {"telegram", telegram_adapter_files()},
        {"discord", ["packages/pincer_discord/lib/pincer/channels/discord.ex"]},
        {"slack", ["packages/pincer_slack/lib/pincer/channels/slack.ex"]}
      ],
      "Formatting",
      "must delegate formatting to Pincer.Channels.Shared.Formatting",
      [
        {"defp wrap_file_references", "must not define a local wrap_file_references/1 copy"}
      ]
    )

    slack_source = File.read!("packages/pincer_slack/lib/pincer/channels/slack.ex")

    refute slack_source =~ "Regex",
           "slack.ex must delegate mrkdwn conversion to Shared.Formatting"
  end

  test "Telegram and Discord delegate attachment helpers to Shared.Attachments" do
    assert_delegates!(
      [
        {"telegram", telegram_adapter_files()},
        {"discord", ["packages/pincer_discord/lib/pincer/channels/discord.ex"]}
      ],
      "Attachments",
      "must delegate attachment handling to Pincer.Channels.Shared.Attachments",
      [
        {"defp sanitize_filename", "must not define a local sanitize_filename/1 copy"},
        {"defp auto_attach_files", "must not define a local auto_attach_files/2 copy"},
        {"defp valid_text_content_type?",
         "must not define a local valid_text_content_type?/1 copy"}
      ]
    )
  end

  test "Telegram, Discord, and WhatsApp delegate DM authorization and /pair to Shared.Pairing" do
    assert_delegates!(
      [
        {"telegram", telegram_adapter_files()},
        {"discord", ["packages/pincer_discord/lib/pincer/channels/discord.ex"]},
        {"whatsapp", ["packages/pincer_whatsapp/lib/pincer/channels/whatsapp.ex"]}
      ],
      "Pairing",
      "must delegate pairing and DM checks to Pincer.Channels.Shared.Pairing",
      [
        {"PincerPorts.ChannelPolicy.approve_code",
         "must not call PincerPorts.ChannelPolicy.approve_code directly"},
        {"PincerPorts.ChannelPolicy.allow?(:dm_access",
         "must not call PincerPorts.ChannelPolicy.allow?(:dm_access directly"}
      ]
    )
  end
end
