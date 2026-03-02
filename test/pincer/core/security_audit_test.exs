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

    test "errors when enabled webhook channel is missing token_env" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        channels:
          webhook:
            enabled: true
            adapter: "Pincer.Channels.Webhook"
        """
      )

      report = SecurityAudit.run(root: tmp, env_fetcher: fn _ -> nil end)

      assert report.status == :error

      assert Enum.any?(report.checks, fn check ->
               check.id == {:channel_auth, "webhook"} and check.severity == :error
             end)
    end

    test "reports ok when enabled webhook channel has token_env present" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        channels:
          webhook:
            enabled: true
            adapter: "Pincer.Channels.Webhook"
            token_env: "PINCER_WEBHOOK_TOKEN"
        """
      )

      report =
        SecurityAudit.run(
          root: tmp,
          env_fetcher: fn
            "PINCER_WEBHOOK_TOKEN" -> "ok-token"
            _ -> nil
          end
        )

      assert Enum.any?(report.checks, fn check ->
               check.id == {:channel_auth, "webhook"} and check.severity == :ok
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

    test "warns when dangerous config flags are enabled" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        gateway:
          control_ui:
            allow_insecure_auth: true
            dangerously_disable_device_auth: true
        tools:
          exec:
            apply_patch:
              workspace_only: false
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
               check.id == {:dangerous_flag, "gateway.control_ui.allow_insecure_auth"} and
                 check.severity == :warn
             end)

      assert Enum.any?(report.checks, fn check ->
               check.id == {:dangerous_flag, "gateway.control_ui.dangerously_disable_device_auth"} and
                 check.severity == :warn
             end)

      assert Enum.any?(report.checks, fn check ->
               check.id == {:dangerous_flag, "tools.exec.apply_patch.workspace_only"} and
                 check.severity == :warn
             end)
    end

    test "errors when tools.restrict_to_workspace is disabled" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        tools:
          restrict_to_workspace: false
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

      assert report.status == :error

      assert Enum.any?(report.checks, fn check ->
               check.id == :tools_restrict_workspace and check.severity == :error
             end)
    end

    test "errors when mcp skills_sidecar isolation is insecure" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        mcp:
          servers:
            skills_sidecar:
              command: "docker"
              artifact_checksum: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
              args:
                - "run"
                - "--read-only"
                - "--network=bridge"
                - "--cap-drop=ALL"
                - "--pids-limit=64"
                - "--memory=256m"
                - "--cpus=1"
                - "--user=1000:1000"
                - "-v"
                - "./skills:/sandbox"
                - "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
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

      assert report.status == :error

      assert Enum.any?(report.checks, fn check ->
               check.id == :mcp_skills_sidecar_isolation and check.severity == :error
             end)
    end

    test "errors when mcp skills_sidecar required flag is overridden unsafely" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        mcp:
          servers:
            skills_sidecar:
              command: "docker"
              artifact_checksum: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
              args:
                - "run"
                - "--read-only"
                - "--network=none"
                - "--network=host"
                - "--cap-drop=ALL"
                - "--pids-limit=64"
                - "--memory=256m"
                - "--cpus=1"
                - "--user=1000:1000"
                - "-v"
                - "./skills:/sandbox"
                - "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
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

      assert report.status == :error

      assert Enum.any?(report.checks, fn check ->
               check.id == :mcp_skills_sidecar_isolation and check.severity == :error
             end)
    end

    test "reports ok when mcp skills_sidecar isolation is hardened" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        mcp:
          servers:
            skills_sidecar:
              command: "docker"
              artifact_checksum: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
              args:
                - "run"
                - "--read-only"
                - "--network=none"
                - "--cap-drop=ALL"
                - "--pids-limit=64"
                - "--memory=256m"
                - "--cpus=1"
                - "--user=1000:1000"
                - "-v"
                - "./skills:/sandbox"
                - "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
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

      assert Enum.any?(report.checks, fn check ->
               check.id == :mcp_skills_sidecar_isolation and check.severity == :ok
             end)
    end

    test "errors when mcp skills_sidecar env contains sensitive keys" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        mcp:
          servers:
            skills_sidecar:
              command: "docker"
              args:
                - "run"
                - "--read-only"
                - "--network=none"
                - "--cap-drop=ALL"
                - "--pids-limit=64"
                - "--memory=256m"
                - "--cpus=1"
                - "--user=1000:1000"
                - "-v"
                - "./skills:/sandbox"
                - "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
              env:
                TELEGRAM_BOT_TOKEN: "super-secret"
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

      assert report.status == :error

      assert Enum.any?(report.checks, fn check ->
               check.id == :mcp_skills_sidecar_isolation and check.severity == :error
             end)
    end

    test "errors when mcp skills_sidecar docker args contain sensitive env keys" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        mcp:
          servers:
            skills_sidecar:
              command: "docker"
              args:
                - "run"
                - "--read-only"
                - "--network=none"
                - "--cap-drop=ALL"
                - "--pids-limit=64"
                - "--memory=256m"
                - "--cpus=1"
                - "--user=1000:1000"
                - "-v"
                - "./skills:/sandbox"
                - "--env"
                - "OPENAI_API_KEY=super-secret"
                - "-e"
                - "TELEGRAM_BOT_TOKEN=secret-2"
                - "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
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

      assert report.status == :error

      assert Enum.any?(report.checks, fn check ->
               check.id == :mcp_skills_sidecar_isolation and check.severity == :error
             end)
    end

    test "errors when mcp skills_sidecar has disallowed mount targets" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        mcp:
          servers:
            skills_sidecar:
              command: "docker"
              args:
                - "run"
                - "--read-only"
                - "--network=none"
                - "--cap-drop=ALL"
                - "--pids-limit=64"
                - "--memory=256m"
                - "--cpus=1"
                - "--user=1000:1000"
                - "-v"
                - "./skills:/sandbox"
                - "-v"
                - "/etc:/host_etc:ro"
                - "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
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

      assert report.status == :error

      assert Enum.any?(report.checks, fn check ->
               check.id == :mcp_skills_sidecar_isolation and check.severity == :error
             end)
    end

    test "errors when mcp skills_sidecar has invalid /sandbox mount source" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        mcp:
          servers:
            skills_sidecar:
              command: "docker"
              args:
                - "run"
                - "--read-only"
                - "--network=none"
                - "--cap-drop=ALL"
                - "--pids-limit=64"
                - "--memory=256m"
                - "--cpus=1"
                - "--user=1000:1000"
                - "-v"
                - "/etc:/sandbox:ro"
                - "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
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

      assert report.status == :error

      assert Enum.any?(report.checks, fn check ->
               check.id == :mcp_skills_sidecar_isolation and check.severity == :error
             end)
    end

    test "errors when mcp skills_sidecar has invalid /tmp mount source" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        mcp:
          servers:
            skills_sidecar:
              command: "docker"
              args:
                - "run"
                - "--read-only"
                - "--network=none"
                - "--cap-drop=ALL"
                - "--pids-limit=64"
                - "--memory=256m"
                - "--cpus=1"
                - "--user=1000:1000"
                - "-v"
                - "./skills:/sandbox"
                - "-v"
                - "/var/run/docker.sock:/tmp:ro"
                - "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
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

      assert report.status == :error

      assert Enum.any?(report.checks, fn check ->
               check.id == :mcp_skills_sidecar_isolation and check.severity == :error
             end)
    end

    test "errors when mcp skills_sidecar has dangerous docker flags" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        mcp:
          servers:
            skills_sidecar:
              command: "docker"
              args:
                - "run"
                - "--read-only"
                - "--network=none"
                - "--cap-drop=ALL"
                - "--pids-limit=64"
                - "--memory=256m"
                - "--cpus=1"
                - "--user=1000:1000"
                - "--privileged"
                - "-v"
                - "./skills:/sandbox"
                - "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
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

      assert report.status == :error

      assert Enum.any?(report.checks, fn check ->
               check.id == :mcp_skills_sidecar_isolation and check.severity == :error
             end)
    end

    test "errors when mcp skills_sidecar uses --mount flag" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        mcp:
          servers:
            skills_sidecar:
              command: "docker"
              args:
                - "run"
                - "--read-only"
                - "--network=none"
                - "--cap-drop=ALL"
                - "--pids-limit=64"
                - "--memory=256m"
                - "--cpus=1"
                - "--user=1000:1000"
                - "-v"
                - "./skills:/sandbox"
                - "--mount=type=bind,src=/etc,dst=/sandbox,ro"
                - "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
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

      assert report.status == :error

      assert Enum.any?(report.checks, fn check ->
               check.id == :mcp_skills_sidecar_isolation and check.severity == :error
             end)
    end

    test "errors when mcp skills_sidecar uses --env-file flag" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        mcp:
          servers:
            skills_sidecar:
              command: "docker"
              args:
                - "run"
                - "--read-only"
                - "--network=none"
                - "--cap-drop=ALL"
                - "--pids-limit=64"
                - "--memory=256m"
                - "--cpus=1"
                - "--user=1000:1000"
                - "-v"
                - "./skills:/sandbox"
                - "--env-file=./.env"
                - "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
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

      assert report.status == :error

      assert Enum.any?(report.checks, fn check ->
               check.id == :mcp_skills_sidecar_isolation and check.severity == :error
             end)
    end

    test "errors when mcp skills_sidecar image is not digest pinned" do
      tmp = tmp_dir!()

      write_config!(
        tmp,
        """
        mcp:
          servers:
            skills_sidecar:
              command: "docker"
              args:
                - "run"
                - "--read-only"
                - "--network=none"
                - "--cap-drop=ALL"
                - "--pids-limit=64"
                - "--memory=256m"
                - "--cpus=1"
                - "--user=1000:1000"
                - "-v"
                - "./skills:/sandbox"
                - "ghcr.io/acme/skills-sidecar:latest"
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

      assert report.status == :error

      assert Enum.any?(report.checks, fn check ->
               check.id == :mcp_skills_sidecar_isolation and check.severity == :error
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
