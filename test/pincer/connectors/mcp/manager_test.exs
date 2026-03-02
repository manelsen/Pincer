defmodule Pincer.Connectors.MCP.ManagerTest do
  use ExUnit.Case, async: false

  alias Pincer.Connectors.MCP.Manager
  alias Pincer.Connectors.MCP.Transports.HTTP
  alias Pincer.Connectors.MCP.Transports.Stdio

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

  defp write_tmp_json!(map) do
    dir = Path.join(System.tmp_dir!(), "pincer_mcp_manager_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "config.json")
    File.write!(path, Jason.encode!(map))
    path
  end
end
