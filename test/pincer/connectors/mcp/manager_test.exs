defmodule Pincer.Adapters.Connectors.MCP.ManagerTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Connectors.MCP.Manager
  alias Pincer.Adapters.Connectors.MCP.Transports.HTTP
  alias Pincer.Adapters.Connectors.MCP.Transports.Stdio

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

  defmodule FakeClient do
    def list_tools(server_pid) do
      case Agent.get_and_update(server_pid, fn state ->
             attempt = state.attempts + 1
             {attempt, %{state | attempts: attempt}}
           end) do
        1 ->
          {:ok, %{"result" => %{"tools" => []}}}

        _ ->
          tools = Agent.get(server_pid, & &1.tools)
          {:ok, %{"result" => %{"tools" => tools}}}
      end
    end

    def call_tool(_server_pid, "slow", args) do
      Process.sleep(80)
      {:ok, %{"result" => %{"content" => [%{"type" => "text", "text" => "slow:#{args["n"]}"}]}}}
    end

    def call_tool(_server_pid, _name, args) do
      {:ok, %{"result" => %{"content" => [%{"type" => "text", "text" => "ok:#{inspect(args)}"}]}}}
    end
  end

  test "build_client_opts/3 and audit_sidecar_result/6 do not intern atoms from unseen keys" do
    unseen_key = "unseen_mcp_key_#{System.unique_integer([:positive])}"
    cfg = %{"command" => "npx", "args" => [], unseen_key => "val"}

    opts = Manager.build_client_opts("custom", cfg, %{})
    assert opts[:command] == "npx"

    assert_raise ArgumentError, fn ->
      String.to_existing_atom(unseen_key)
    end
  end

  describe "non-blocking discovery and concurrent execution" do
    setup do
      tools = [
        %{"name" => "slow", "description" => "Slow tool", "inputSchema" => %{"type" => "object"}}
      ]

      {:ok, fake_srv} = Agent.start_link(fn -> %{attempts: 0, tools: tools} end)

      on_exit(fn ->
        if Process.alive?(fake_srv), do: Agent.stop(fake_srv)
      end)

      {:ok, fake_srv: fake_srv}
    end

    test "boots and responds to get_all_tools immediately without blocking on retry interval", %{
      fake_srv: fake_srv
    } do
      start_ms = System.monotonic_time(:millisecond)

      pid =
        start_supervised!(
          {Manager,
           name: nil,
           servers: %{"fake" => fake_srv},
           client_module: FakeClient,
           retry_interval_ms: 5_000,
           max_retries: 2}
        )

      tools = Manager.get_all_tools(pid, 100)
      elapsed_ms = System.monotonic_time(:millisecond) - start_ms

      assert is_list(tools)
      assert elapsed_ms < 250
    end

    test "retries discovery asynchronously and populates tools on subsequent attempts", %{
      fake_srv: fake_srv
    } do
      pid =
        start_supervised!(
          {Manager,
           name: nil,
           servers: %{"fake" => fake_srv},
           client_module: FakeClient,
           retry_interval_ms: 15,
           max_retries: 3}
        )

      eventually(fn ->
        tools = Manager.get_all_tools(pid, 200)
        assert Enum.any?(tools, &(&1.name == "slow"))
      end)
    end

    test "execute_tool runs concurrently across callers without blocking Manager GenServer", %{
      fake_srv: fake_srv
    } do
      pid =
        start_supervised!(
          {Manager,
           name: nil,
           servers: %{"fake" => fake_srv},
           client_module: FakeClient,
           retry_interval_ms: 10,
           max_retries: 3}
        )

      eventually(fn ->
        assert Enum.any?(Manager.get_all_tools(pid, 200), &(&1.name == "slow"))
      end)

      t0 = System.monotonic_time(:millisecond)

      t1 = Task.async(fn -> Manager.execute_tool(pid, "slow", %{"n" => 1}) end)
      t2 = Task.async(fn -> Manager.execute_tool(pid, "slow", %{"n" => 2}) end)

      # Manager stays responsive to get_all_tools while slow tools execute
      Process.sleep(15)
      t_query_start = System.monotonic_time(:millisecond)
      _tools = Manager.get_all_tools(pid, 50)
      assert System.monotonic_time(:millisecond) - t_query_start < 40

      assert {:ok, "slow:1"} = Task.await(t1, 1_000)
      assert {:ok, "slow:2"} = Task.await(t2, 1_000)

      elapsed_ms = System.monotonic_time(:millisecond) - t0
      assert elapsed_ms < 145
    end
  end

  test "call_tool_with_timeout/4 catches sidecar exits without crashing caller" do
    result =
      Manager.call_tool_with_timeout(
        "skills_sidecar",
        fn -> exit(:boom) end,
        200,
        5
      )

    assert {:error, :boom} = result
  end

  describe "per-agent ACLs and trusted context propagation" do
    defmodule ContextCapturingClient do
      def list_tools(_server_pid) do
        {:ok,
         %{
           "result" => %{
             "tools" => [
               %{
                 "name" => "fs_read",
                 "description" => "Read workspace file",
                 "inputSchema" => %{
                   "type" => "object",
                   "properties" => %{"path" => %{"type" => "string"}}
                 }
               }
             ]
           }
         }}
      end

      def call_tool(_server_pid, name, args, meta) do
        if pid = Application.get_env(:pincer, :mcp_context_test_pid) do
          send(pid, {:mcp_client_call, name, args, meta})
        end

        {:ok, %{"result" => %{"content" => [%{"type" => "text", "text" => "read-ok"}]}}}
      end
    end

    test "enforces allowed_agents, strips spoofed _meta, confines workspace paths, and forwards verified meta" do
      ws_a = Path.join(System.tmp_dir!(), "mcp_ws_a_#{System.unique_integer([:positive])}")
      ws_b = Path.join(System.tmp_dir!(), "mcp_ws_b_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(ws_a, "notes"))
      File.mkdir_p!(ws_b)
      File.write!(Path.join(ws_a, "notes/todo.txt"), "ok")
      Application.put_env(:pincer, :mcp_context_test_pid, self())

      on_exit(fn ->
        Application.delete_env(:pincer, :mcp_context_test_pid)
        File.rm_rf(ws_a)
        File.rm_rf(ws_b)
      end)

      {:ok, fake_srv} = Agent.start_link(fn -> %{} end)
      on_exit(fn -> if Process.alive?(fake_srv), do: Agent.stop(fake_srv) end)

      pid =
        start_supervised!(
          {Manager,
           name: nil,
           servers: %{"scoped_fs" => fake_srv},
           server_policies: %{
             "scoped_fs" => %{
               "allowed_agents" => ["agent_a"],
               "workspace_confined" => true
             }
           },
           client_module: ContextCapturingClient,
           retry_interval_ms: 10,
           max_retries: 2}
        )

      ctx_a = %{"session_id" => "telegram_1", "agent_id" => "agent_a", "workspace_path" => ws_a}
      ctx_b = %{"session_id" => "telegram_2", "agent_id" => "agent_b", "workspace_path" => ws_b}

      eventually(fn ->
        tools_a = Manager.get_tools_for_context(pid, ctx_a, 200)
        assert Enum.any?(tools_a, &(&1.name == "fs_read"))
      end)

      assert Manager.get_tools_for_context(pid, ctx_b, 200) == []

      assert {:error, {:mcp_access_denied, "scoped_fs"}} =
               Manager.execute_tool_with_context(
                 pid,
                 "fs_read",
                 %{"path" => "notes/todo.txt"},
                 ctx_b
               )

      refute_received {:mcp_client_call, _, _, _}

      assert {:error, {:mcp_path_outside_workspace, _reason}} =
               Manager.execute_tool_with_context(
                 pid,
                 "fs_read",
                 %{"path" => "../#{Path.basename(ws_b)}/secret.txt"},
                 ctx_a
               )

      refute_received {:mcp_client_call, _, _, _}

      assert {:ok, "read-ok"} =
               Manager.execute_tool_with_context(
                 pid,
                 "fs_read",
                 %{"path" => "notes/todo.txt", "_meta" => %{"agent_id" => "spoofed_admin"}},
                 ctx_a
               )

      assert_received {:mcp_client_call, "fs_read", args, meta}
      refute Map.has_key?(args, "_meta")
      assert args["path"] == Path.join(ws_a, "notes/todo.txt")
      assert meta["agent_id"] == "agent_a"
      assert meta["session_id"] == "telegram_1"
      assert meta["workspace_path"] == ws_a
    end
  end

  defp eventually(fun) do
    Pincer.Test.Support.SyncHelpers.eventually(fun, timeout: 600, interval: 20)
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
