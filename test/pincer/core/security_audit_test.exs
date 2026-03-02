defmodule Pincer.Core.SecurityAuditTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.SecurityAudit

  describe "run/1" do
    test "warns when dm policy is open on enabled channel" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        channels:
          telegram:
            enabled: true
            token_env: "TELEGRAM_BOT_TOKEN"
            dm_policy:
              mode: "open"
        """
      )

      report =
        SecurityAudit.run(
          root: tmp,
          env_fetcher: fn
            "TELEGRAM_BOT_TOKEN" -> "token"
            _ -> nil
          end
        )

      assert report.status == :warn

      assert Enum.any?(report.checks, fn check ->
               check.id == {:dm_policy, "telegram"} and check.severity == :warn
             end)
    end

    test "errors when enabled channel is missing auth token env" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        channels:
          discord:
            enabled: true
            token_env: "DISCORD_BOT_TOKEN"
            dm_policy:
              mode: "disabled"
        """
      )

      report = SecurityAudit.run(root: tmp, env_fetcher: fn _ -> nil end)

      assert report.status == :error
      assert report.counts.error >= 1

      assert Enum.any?(report.checks, fn check ->
               check.id == {:channel_auth, "discord"} and check.severity == :error
             end)
    end

    test "warns on risky gateway bind configuration" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        gateway:
          bind: "0.0.0.0"
        channels:
          telegram:
            enabled: true
            token_env: "TELEGRAM_BOT_TOKEN"
            dm_policy:
              mode: "allowlist"
              allow_from: ["123"]
        """
      )

      report =
        SecurityAudit.run(
          root: tmp,
          env_fetcher: fn
            "TELEGRAM_BOT_TOKEN" -> "token"
            _ -> nil
          end
        )

      assert report.status == :warn

      assert Enum.any?(report.checks, fn check ->
               check.id == :gateway_bind and check.severity == :warn
             end)
    end

    test "returns ok for secure baseline configuration" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        gateway:
          bind: "127.0.0.1"
        channels:
          telegram:
            enabled: true
            token_env: "TELEGRAM_BOT_TOKEN"
            dm_policy:
              mode: "allowlist"
              allow_from: ["123"]
          discord:
            enabled: true
            token_env: "DISCORD_BOT_TOKEN"
            dm_policy:
              mode: "disabled"
        """
      )

      report =
        SecurityAudit.run(
          root: tmp,
          env_fetcher: fn
            "TELEGRAM_BOT_TOKEN" -> "token-telegram"
            "DISCORD_BOT_TOKEN" -> "token-discord"
            _ -> nil
          end
        )

      assert report.status == :ok
      assert report.counts.error == 0
      assert report.counts.warn == 0
    end
  end

  defp tmp_dir! do
    tmp =
      Path.join(System.tmp_dir!(), "pincer_security_audit_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
    end)

    tmp
  end

  defp write_config!(tmp, content) do
    File.write!(Path.join(tmp, "config.yaml"), String.trim_leading(content))
  end
end
