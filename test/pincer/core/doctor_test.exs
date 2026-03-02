defmodule Pincer.Core.DoctorTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Doctor

  describe "run/1" do
    test "returns error when config.yaml is invalid" do
      tmp = tmp_dir!()
      File.write!(Path.join(tmp, "config.yaml"), "channels:\n  telegram: [")

      report = Doctor.run(root: tmp)

      assert report.status == :error
      assert report.counts.error >= 1

      assert Enum.any?(report.checks, fn check ->
               check.id == :config_yaml and check.severity == :error
             end)
    end

    test "returns error when enabled channel token is missing" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        channels:
          telegram:
            enabled: true
            token_env: "TELEGRAM_BOT_TOKEN"
            dm_policy:
              mode: "allowlist"
              allow_from: ["123"]
        """
      )

      report = Doctor.run(root: tmp, env_fetcher: fn _ -> nil end)

      assert report.status == :error

      assert Enum.any?(report.checks, fn check ->
               check.id == {:channel_token, "telegram"} and check.severity == :error
             end)
    end

    test "returns warning when dm policy is open" do
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
        Doctor.run(
          root: tmp,
          env_fetcher: fn
            "TELEGRAM_BOT_TOKEN" -> "token"
            _ -> nil
          end
        )

      assert report.status == :warn
      assert report.counts.warn >= 1

      assert Enum.any?(report.checks, fn check ->
               check.id == {:dm_policy, "telegram"} and check.severity == :warn
             end)
    end

    test "evaluates dm policy for whatsapp without requiring token_env" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        channels:
          whatsapp:
            enabled: true
            dm_policy:
              mode: "open"
        """
      )

      report = Doctor.run(root: tmp, env_fetcher: fn _ -> nil end)

      assert report.status == :warn

      assert Enum.any?(report.checks, fn check ->
               check.id == {:dm_policy, "whatsapp"} and check.severity == :warn
             end)

      refute Enum.any?(report.checks, fn check ->
               check.id == {:channel_token, "whatsapp"} and check.severity == :error
             end)
    end

    test "returns ok for valid config, secure dm policy and available tokens" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
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
        Doctor.run(
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
    tmp = Path.join(System.tmp_dir!(), "pincer_doctor_#{System.unique_integer([:positive])}")
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
