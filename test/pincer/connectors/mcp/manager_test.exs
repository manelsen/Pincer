defmodule Pincer.Connectors.MCP.ManagerTest do
  use ExUnit.Case, async: false

  alias Pincer.Connectors.MCP.Manager
  alias Pincer.Connectors.MCP.Transports.HTTP
  alias Pincer.Connectors.MCP.Transports.Stdio

  defmodule SidecarAuditSpy do
    def status_from_result({:ok, _}), do: :ok
    def status_from_result({:error, :timeout}), do: :timeout
    def status_from_result({:error, :blocked}), do: :blocked
    def status_from_result({:error, _}), do: :error
    def status_from_result(_), do: :error

    def emit(skill_id, tool_name, duration_ms, status, metadata) do
      send(self(), {:sidecar_audit, skill_id, tool_name, duration_ms, status, metadata})
      :ok
    end
  end

  test "get_all_tools/1 returns empty list on timeout instead of exiting caller" do
    assert Manager.get_all_tools(0) == []
  end

  test "build_client_opts/3 keeps stdio default and injects github env token" do
    cfg = %{"command" => "npx", "args" => ["-y", "@modelcontextprotocol/server-github"]}
    tokens = %{"github" => "ghp_token"}

    opts = Manager.build_client_opts("github", cfg, tokens)

    assert opts[:transport] == Stdio
    assert opts[:command] == "npx"
    assert opts[:args] == ["-y", "@modelcontextprotocol/server-github"]
    assert {"GITHUB_PERSONAL_ACCESS_TOKEN", "ghp_token"} in opts[:env]
  end

  test "build_client_opts/3 maps http transport with url and custom headers" do
    cfg = %{
      "transport" => "http",
      "url" => "https://mcp.example.com/rpc",
      "headers" => %{"Authorization" => "Bearer abc", "X-Tenant" => "acme"}
    }

    opts = Manager.build_client_opts("remote", cfg, %{})

    assert opts[:transport] == HTTP
    assert opts[:url] == "https://mcp.example.com/rpc"
    assert {"Authorization", "Bearer abc"} in opts[:headers]
    assert {"X-Tenant", "acme"} in opts[:headers]
  end

  test "resolve_servers_config/2 merges dynamic config.json servers" do
    path =
      write_tmp_json!(%{
        "mcpServers" => %{
          "filesystem" => %{
            "command" => "npx",
            "args" => ["-y", "@modelcontextprotocol/server-filesystem", "."]
          }
        }
      })

    mcp_config = %{"servers" => %{}}

    servers = Manager.resolve_servers_config(mcp_config, paths: [path])

    assert get_in(servers, ["filesystem", "command"]) == "npx"
  end

  test "resolve_servers_config/2 preserves static server precedence over dynamic" do
    path =
      write_tmp_json!(%{
        "mcpServers" => %{
          "filesystem" => %{
            "command" => "dynamic-cmd",
            "args" => ["--dynamic"]
          }
        }
      })

    mcp_config = %{
      "servers" => %{
        "filesystem" => %{"command" => "static-cmd", "args" => ["--static"]}
      }
    }

    servers = Manager.resolve_servers_config(mcp_config, paths: [path])

    assert get_in(servers, ["filesystem", "command"]) == "static-cmd"
    assert get_in(servers, ["filesystem", "args"]) == ["--static"]
  end

  test "resolve_servers_config/2 drops insecure skills_sidecar server" do
    mcp_config = %{
      "servers" => %{
        "skills_sidecar" => %{
          "command" => "docker",
          "artifact_checksum" =>
            "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "args" => [
            "run",
            "--read-only",
            "--network=bridge",
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
      }
    }

    servers = Manager.resolve_servers_config(mcp_config)

    refute Map.has_key?(servers, "skills_sidecar")
  end

  test "resolve_servers_config/2 drops skills_sidecar when required flag is overridden unsafely" do
    mcp_config = %{
      "servers" => %{
        "skills_sidecar" => %{
          "command" => "docker",
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
      }
    }

    servers = Manager.resolve_servers_config(mcp_config)

    refute Map.has_key?(servers, "skills_sidecar")
  end

  test "resolve_servers_config/2 keeps hardened skills_sidecar server" do
    mcp_config = %{
      "servers" => %{
        "skills_sidecar" => %{
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
      }
    }

    servers = Manager.resolve_servers_config(mcp_config)

    assert get_in(servers, ["skills_sidecar", "command"]) == "docker"
  end

  test "resolve_servers_config/2 drops skills_sidecar with sensitive env keys" do
    mcp_config = %{
      "servers" => %{
        "skills_sidecar" => %{
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
      }
    }

    servers = Manager.resolve_servers_config(mcp_config)

    refute Map.has_key?(servers, "skills_sidecar")
  end

  test "resolve_servers_config/2 drops skills_sidecar with sensitive env keys in docker args" do
    mcp_config = %{
      "servers" => %{
        "skills_sidecar" => %{
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
      }
    }

    servers = Manager.resolve_servers_config(mcp_config)

    refute Map.has_key?(servers, "skills_sidecar")
  end

  test "resolve_servers_config/2 drops skills_sidecar with disallowed mount target" do
    mcp_config = %{
      "servers" => %{
        "skills_sidecar" => %{
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
      }
    }

    servers = Manager.resolve_servers_config(mcp_config)

    refute Map.has_key?(servers, "skills_sidecar")
  end

  test "resolve_servers_config/2 drops skills_sidecar with invalid /sandbox mount source" do
    mcp_config = %{
      "servers" => %{
        "skills_sidecar" => %{
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
      }
    }

    servers = Manager.resolve_servers_config(mcp_config)

    refute Map.has_key?(servers, "skills_sidecar")
  end

  test "resolve_servers_config/2 drops skills_sidecar with invalid /tmp mount source" do
    mcp_config = %{
      "servers" => %{
        "skills_sidecar" => %{
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
      }
    }

    servers = Manager.resolve_servers_config(mcp_config)

    refute Map.has_key?(servers, "skills_sidecar")
  end

  test "resolve_servers_config/2 drops skills_sidecar with dangerous docker flags" do
    mcp_config = %{
      "servers" => %{
        "skills_sidecar" => %{
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
            "-v",
            "./skills:/sandbox",
            "ghcr.io/acme/skills-sidecar@sha256:1111111111111111111111111111111111111111111111111111111111111111"
          ]
        }
      }
    }

    servers = Manager.resolve_servers_config(mcp_config)

    refute Map.has_key?(servers, "skills_sidecar")
  end

  test "resolve_servers_config/2 drops skills_sidecar with --mount flag" do
    mcp_config = %{
      "servers" => %{
        "skills_sidecar" => %{
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
      }
    }

    servers = Manager.resolve_servers_config(mcp_config)

    refute Map.has_key?(servers, "skills_sidecar")
  end

  test "resolve_servers_config/2 drops skills_sidecar with --env-file flag" do
    mcp_config = %{
      "servers" => %{
        "skills_sidecar" => %{
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
      }
    }

    servers = Manager.resolve_servers_config(mcp_config)

    refute Map.has_key?(servers, "skills_sidecar")
  end

  test "resolve_servers_config/2 drops skills_sidecar with unpinned image digest" do
    mcp_config = %{
      "servers" => %{
        "skills_sidecar" => %{
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
      }
    }

    servers = Manager.resolve_servers_config(mcp_config)

    refute Map.has_key?(servers, "skills_sidecar")
  end

  test "audit_sidecar_result/5 emits audit for skills_sidecar and preserves result" do
    started_at = System.monotonic_time(:millisecond) - 10
    result = {:ok, "done"}

    assert result ==
             Manager.audit_sidecar_result(
               "skills_sidecar",
               "run_skill",
               started_at,
               result,
               SidecarAuditSpy
             )

    assert_receive {:sidecar_audit, "skills_sidecar", "run_skill", duration_ms, :ok,
                    %{skill_version: "unknown"}}

    assert duration_ms >= 0
  end

  test "audit_sidecar_result/6 propagates skill metadata from tool arguments" do
    started_at = System.monotonic_time(:millisecond) - 10
    result = {:ok, "done"}

    args = %{
      "skill_id" => "safeclaw.log_parser",
      "skill_version" => "1.2.3",
      "artifact_checksum" =>
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }

    assert result ==
             Manager.audit_sidecar_result(
               "skills_sidecar",
               "run_skill",
               started_at,
               result,
               SidecarAuditSpy,
               args
             )

    assert_receive {:sidecar_audit, "safeclaw.log_parser", "run_skill", duration_ms, :ok,
                    %{skill_version: "1.2.3", artifact_checksum: checksum}}

    assert checksum == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    assert duration_ms >= 0
  end

  test "audit_sidecar_result/5 skips non-sidecar servers" do
    started_at = System.monotonic_time(:millisecond) - 10
    result = {:ok, "done"}

    assert result ==
             Manager.audit_sidecar_result(
               "filesystem",
               "read_file",
               started_at,
               result,
               SidecarAuditSpy
             )

    refute_receive {:sidecar_audit, _, _, _, _, _}
  end

  test "call_tool_with_timeout/4 returns success for sidecar within timeout" do
    result =
      Manager.call_tool_with_timeout(
        "skills_sidecar",
        fn -> {:ok, %{"result" => %{"content" => [%{"type" => "text", "text" => "ok"}]}}} end,
        50,
        5
      )

    assert {:ok, %{"result" => %{"content" => [%{"text" => "ok"}]}}} = result
  end

  test "call_tool_with_timeout/4 returns timeout for sidecar over limit" do
    result =
      Manager.call_tool_with_timeout(
        "skills_sidecar",
        fn ->
          Process.sleep(30)
          {:ok, %{"result" => %{"content" => []}}}
        end,
        5,
        0
      )

    assert {:error, :timeout} = result
  end

  test "call_tool_with_timeout/4 bypasses hard-timeout for non-sidecar servers" do
    result =
      Manager.call_tool_with_timeout(
        "filesystem",
        fn ->
          Process.sleep(15)
          {:ok, %{"result" => %{"content" => []}}}
        end,
        1,
        0
      )

    assert {:ok, %{"result" => %{"content" => []}}} = result
  end

  defp write_tmp_json!(map) do
    dir = Path.join(System.tmp_dir!(), "pincer_mcp_manager_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "config.json")
    File.write!(path, Jason.encode!(map))
    path
  end
end
