defmodule Pincer.Connectors.MCP.ConfigLoaderTest do
  use ExUnit.Case, async: true

  alias Pincer.Connectors.MCP.ConfigLoader

  describe "discover_servers/1" do
    test "loads Cursor/Claude style mcpServers map" do
      path =
        write_tmp_json!(%{
          "mcpServers" => %{
            "filesystem" => %{
              "command" => "npx",
              "args" => ["-y", "@modelcontextprotocol/server-filesystem", "."]
            }
          }
        })

      servers = ConfigLoader.discover_servers(paths: [path])

      assert get_in(servers, ["filesystem", "command"]) == "npx"

      assert get_in(servers, ["filesystem", "args"]) == [
               "-y",
               "@modelcontextprotocol/server-filesystem",
               "."
             ]
    end

    test "loads nested mcp.servers map" do
      path =
        write_tmp_json!(%{
          "mcp" => %{
            "servers" => %{
              "github" => %{
                "command" => "npx",
                "args" => ["-y", "@modelcontextprotocol/server-github"]
              }
            }
          }
        })

      servers = ConfigLoader.discover_servers(paths: [path])

      assert get_in(servers, ["github", "command"]) == "npx"
      assert get_in(servers, ["github", "args"]) == ["-y", "@modelcontextprotocol/server-github"]
    end

    test "ignores invalid JSON and missing files" do
      invalid_path = write_tmp_raw!("{invalid-json")
      missing_path = invalid_path <> ".missing"

      assert ConfigLoader.discover_servers(paths: [invalid_path, missing_path]) == %{}
    end

    test "filters disabled dynamic servers" do
      path =
        write_tmp_json!(%{
          "mcpServers" => %{
            "enabled_server" => %{"command" => "npx", "args" => ["-y", "ok"]},
            "disabled_server" => %{"command" => "npx", "args" => ["-y", "no"], "disabled" => true}
          }
        })

      servers = ConfigLoader.discover_servers(paths: [path])

      assert Map.has_key?(servers, "enabled_server")
      refute Map.has_key?(servers, "disabled_server")
    end
  end

  describe "merge_static_and_dynamic/2" do
    test "static servers override dynamic servers with same name" do
      path =
        write_tmp_json!(%{
          "mcpServers" => %{
            "filesystem" => %{
              "command" => "dynamic-cmd",
              "args" => ["--dynamic"]
            },
            "github" => %{
              "command" => "npx",
              "args" => ["-y", "@modelcontextprotocol/server-github"]
            }
          }
        })

      static_servers = %{
        "filesystem" => %{"command" => "static-cmd", "args" => ["--static"]}
      }

      merged = ConfigLoader.merge_static_and_dynamic(static_servers, paths: [path])

      assert get_in(merged, ["filesystem", "command"]) == "static-cmd"
      assert get_in(merged, ["filesystem", "args"]) == ["--static"]
      assert get_in(merged, ["github", "command"]) == "npx"
    end
  end

  defp write_tmp_json!(map) do
    map
    |> Jason.encode!()
    |> write_tmp_raw!()
  end

  defp write_tmp_raw!(content) when is_binary(content) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "pincer_mcp_config_loader_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "config.json")
    File.write!(path, content)
    path
  end
end
