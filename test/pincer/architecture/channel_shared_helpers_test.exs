defmodule Pincer.Architecture.ChannelSharedHelpersTest do
  use ExUnit.Case, async: true

  test "channels delegate chunking and streaming buffer flushes to Shared.Chunking" do
    chunking_files = [
      "packages/pincer_telegram/lib/pincer/channels/telegram.ex",
      "packages/pincer_discord/lib/pincer/channels/discord.ex",
      "packages/pincer_whatsapp/lib/pincer/channels/whatsapp.ex",
      "packages/pincer_line/lib/pincer/channels/line/session.ex"
    ]

    for file <- chunking_files do
      source = File.read!(file)

      assert source =~ "Chunking",
             "#{file} must delegate chunking to Pincer.Channels.Shared.Chunking"

      refute source =~ "defp smart_chunk_text",
             "#{file} must not define a local smart_chunk_text/2 copy"

      refute source =~ "defp find_last_newline_within",
             "#{file} must not define a local find_last_newline_within/2 copy"

      refute source =~ "defp split_outbound_chunks",
             "#{file} must not define a local split_outbound_chunks/1 copy"

      refute source =~ "@sentence_boundary",
             "#{file} must delegate stream boundary detection to Shared.Chunking"
    end
  end

  test "channels delegate formatting helpers to Shared.Formatting" do
    formatting_files = [
      "packages/pincer_telegram/lib/pincer/channels/telegram.ex",
      "packages/pincer_discord/lib/pincer/channels/discord.ex",
      "packages/pincer_slack/lib/pincer/channels/slack.ex"
    ]

    for file <- formatting_files do
      source = File.read!(file)

      assert source =~ "Formatting",
             "#{file} must delegate formatting to Pincer.Channels.Shared.Formatting"

      refute source =~ "defp wrap_file_references",
             "#{file} must not define a local wrap_file_references/1 copy"
    end

    slack_source = File.read!("packages/pincer_slack/lib/pincer/channels/slack.ex")

    refute slack_source =~ "Regex",
           "slack.ex must delegate mrkdwn conversion to Shared.Formatting"
  end

  test "Telegram and Discord delegate attachment helpers to Shared.Attachments" do
    attachment_files = [
      "packages/pincer_telegram/lib/pincer/channels/telegram.ex",
      "packages/pincer_discord/lib/pincer/channels/discord.ex"
    ]

    for file <- attachment_files do
      source = File.read!(file)

      assert source =~ "Attachments",
             "#{file} must delegate attachment handling to Pincer.Channels.Shared.Attachments"

      refute source =~ "defp sanitize_filename",
             "#{file} must not define a local sanitize_filename/1 copy"

      refute source =~ "defp auto_attach_files",
             "#{file} must not define a local auto_attach_files/2 copy"

      refute source =~ "defp valid_text_content_type?",
             "#{file} must not define a local valid_text_content_type?/1 copy"
    end
  end

  test "Telegram, Discord, and WhatsApp delegate DM authorization and /pair to Shared.Pairing" do
    pairing_files = [
      "packages/pincer_telegram/lib/pincer/channels/telegram.ex",
      "packages/pincer_discord/lib/pincer/channels/discord.ex",
      "packages/pincer_whatsapp/lib/pincer/channels/whatsapp.ex"
    ]

    for file <- pairing_files do
      source = File.read!(file)

      assert source =~ "Pairing",
             "#{file} must delegate pairing and DM checks to Pincer.Channels.Shared.Pairing"

      refute source =~ "PincerPorts.ChannelPolicy.approve_code",
             "#{file} must not call PincerPorts.ChannelPolicy.approve_code directly"

      refute source =~ "PincerPorts.ChannelPolicy.allow?(:dm_access",
             "#{file} must not call PincerPorts.ChannelPolicy.allow?(:dm_access directly"
    end
  end
end
