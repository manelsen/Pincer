defmodule Pincer.Connectors.MCP.SkillsSidecarPolicyTest do
  use ExUnit.Case, async: true

  alias Pincer.Connectors.MCP.SkillsSidecarPolicy

  describe "validate/1" do
    test "accepts hardened docker sidecar config" do
      cfg = %{
        "command" => "docker",
        "artifact_checksum" =>
          "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "-v",
          "./skills:/sandbox",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ]
      }

      assert :ok = SkillsSidecarPolicy.validate(cfg)
    end

    test "rejects config without docker command" do
      cfg = %{
        "command" => "node",
        "args" => ["index.js"]
      }

      assert {:error, :invalid_command} = SkillsSidecarPolicy.validate(cfg)
    end

    test "rejects config when required isolation flags are missing" do
      cfg = %{
        "command" => "docker",
        "artifact_checksum" =>
          "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--user=1000:1000",
          "-v",
          "./skills:/sandbox",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ]
      }

      assert {:error, {:missing_required_flags, missing}} = SkillsSidecarPolicy.validate(cfg)
      assert "--pids-limit" in missing
      assert "--memory" in missing
      assert "--cpus" in missing
    end

    test "rejects config when required isolation flag is overridden later with unsafe value" do
      cfg = %{
        "command" => "docker",
        "artifact_checksum" =>
          "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--network=host",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "-v",
          "./skills:/sandbox",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ]
      }

      assert {:error, {:missing_required_flags, missing}} = SkillsSidecarPolicy.validate(cfg)
      assert "--network=none" in missing
    end

    test "rejects root user" do
      cfg = %{
        "command" => "docker",
        "artifact_checksum" =>
          "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=0:0",
          "-v",
          "./skills:/sandbox",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ]
      }

      assert {:error, :root_user_not_allowed} = SkillsSidecarPolicy.validate(cfg)
    end

    test "rejects missing sandbox mount" do
      cfg = %{
        "command" => "docker",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ]
      }

      assert {:error, :sandbox_mount_required} = SkillsSidecarPolicy.validate(cfg)
    end

    test "rejects sensitive env keys in map format" do
      cfg = %{
        "command" => "docker",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "-v",
          "./skills:/sandbox",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ],
        "env" => %{
          "SKILL_MODE" => "strict",
          "TELEGRAM_BOT_TOKEN" => "super-secret"
        }
      }

      assert {:error, {:sensitive_env_keys_blocked, blocked}} = SkillsSidecarPolicy.validate(cfg)
      assert blocked == ["TELEGRAM_BOT_TOKEN"]
    end

    test "rejects sensitive env keys in list format" do
      cfg = %{
        "command" => "docker",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "-v",
          "./skills:/sandbox",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ],
        "env" => [{"OPENAI_API_KEY", "super-secret"}, "SKILL_MODE=strict"]
      }

      assert {:error, {:sensitive_env_keys_blocked, blocked}} = SkillsSidecarPolicy.validate(cfg)
      assert blocked == ["OPENAI_API_KEY"]
    end

    test "rejects sensitive env keys passed through docker args" do
      cfg = %{
        "command" => "docker",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "-v",
          "./skills:/sandbox",
          "--env",
          "OPENAI_API_KEY=super-secret",
          "-e",
          "TELEGRAM_BOT_TOKEN=secret-2",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ]
      }

      assert {:error, {:sensitive_env_keys_blocked, blocked}} = SkillsSidecarPolicy.validate(cfg)
      assert blocked == ["OPENAI_API_KEY", "TELEGRAM_BOT_TOKEN"]
    end

    test "accepts non-sensitive env keys" do
      cfg = %{
        "command" => "docker",
        "artifact_checksum" =>
          "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "-v",
          "./skills:/sandbox",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ],
        "env" => [{"SKILL_MODE", "strict"}, "FEATURE_FLAG=1"]
      }

      assert :ok = SkillsSidecarPolicy.validate(cfg)
    end

    test "accepts non-sensitive env keys passed through docker args" do
      cfg = %{
        "command" => "docker",
        "artifact_checksum" =>
          "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "-v",
          "./skills:/sandbox",
          "--env",
          "SKILL_MODE=strict",
          "-e",
          "FEATURE_FLAG=1",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ]
      }

      assert :ok = SkillsSidecarPolicy.validate(cfg)
    end

    test "rejects disallowed mount targets" do
      cfg = %{
        "command" => "docker",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "-v",
          "./skills:/sandbox",
          "-v",
          "/etc:/host_etc:ro",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ]
      }

      assert {:error, {:disallowed_mount_targets, targets}} = SkillsSidecarPolicy.validate(cfg)
      assert targets == ["/host_etc"]
    end

    test "accepts optional /tmp mount target" do
      cfg = %{
        "command" => "docker",
        "artifact_checksum" =>
          "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "-v",
          "./skills:/sandbox",
          "-v",
          "pincer-tmp:/tmp",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ]
      }

      assert :ok = SkillsSidecarPolicy.validate(cfg)
    end

    test "rejects absolute source for /sandbox mount target" do
      cfg = %{
        "command" => "docker",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "-v",
          "/etc:/sandbox:ro",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ]
      }

      assert {:error, {:invalid_sandbox_mount_sources, sources}} =
               SkillsSidecarPolicy.validate(cfg)

      assert sources == ["/etc"]
    end

    test "rejects named volume source for /sandbox mount target" do
      cfg = %{
        "command" => "docker",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "-v",
          "pincer-skills:/sandbox",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ]
      }

      assert {:error, {:invalid_sandbox_mount_sources, sources}} =
               SkillsSidecarPolicy.validate(cfg)

      assert sources == ["pincer-skills"]
    end

    test "rejects path source for /tmp mount target" do
      cfg = %{
        "command" => "docker",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "-v",
          "./skills:/sandbox",
          "-v",
          "/var/run/docker.sock:/tmp:ro",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ]
      }

      assert {:error, {:invalid_tmp_mount_sources, sources}} = SkillsSidecarPolicy.validate(cfg)
      assert sources == ["/var/run/docker.sock"]
    end

    test "rejects dangerous docker runtime flags" do
      cfg = %{
        "command" => "docker",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "--privileged",
          "--cap-add=SYS_ADMIN",
          "-v",
          "./skills:/sandbox",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ]
      }

      assert {:error, {:dangerous_docker_flags, flags}} = SkillsSidecarPolicy.validate(cfg)
      assert "--cap-add" in flags
      assert "--privileged" in flags
    end

    test "rejects --mount flag to prevent mount parser bypass" do
      cfg = %{
        "command" => "docker",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "-v",
          "./skills:/sandbox",
          "--mount=type=bind,src=/etc,dst=/sandbox,ro",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ]
      }

      assert {:error, {:dangerous_docker_flags, flags}} = SkillsSidecarPolicy.validate(cfg)
      assert "--mount" in flags
    end

    test "rejects --env-file flag to prevent host env-file injection" do
      cfg = %{
        "command" => "docker",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "-v",
          "./skills:/sandbox",
          "--env-file=./.env",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ]
      }

      assert {:error, {:dangerous_docker_flags, flags}} = SkillsSidecarPolicy.validate(cfg)
      assert "--env-file" in flags
    end

    test "rejects unpinned image digest" do
      cfg = %{
        "command" => "docker",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "-v",
          "./skills:/sandbox",
          "ghcr.io/acme/skills-sidecar:latest"
        ]
      }

      assert {:error, :unpinned_image_digest} = SkillsSidecarPolicy.validate(cfg)
    end

    test "rejects sidecar config without artifact checksum" do
      cfg = %{
        "command" => "docker",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "-v",
          "./skills:/sandbox",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ]
      }

      assert {:error, :artifact_checksum_required} = SkillsSidecarPolicy.validate(cfg)
    end

    test "rejects sidecar config with invalid artifact checksum format" do
      cfg = %{
        "command" => "docker",
        "artifact_checksum" => "sha256:xyz",
        "args" => [
          "run",
          "--read-only",
          "--network=none",
          "--cap-drop=ALL",
          "--pids-limit=64",
          "--memory=256m",
          "--cpus=1",
          "--user=1000:1000",
          "-v",
          "./skills:/sandbox",
          "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        ]
      }

      assert {:error, :invalid_artifact_checksum} = SkillsSidecarPolicy.validate(cfg)
    end
  end

  test "sensitive_env_keys/0 exposes explicit denylist" do
    denylist = SkillsSidecarPolicy.sensitive_env_keys()

    assert "TELEGRAM_BOT_TOKEN" in denylist
    assert "OPENAI_API_KEY" in denylist
    assert "DATABASE_URL" in denylist
  end
end
