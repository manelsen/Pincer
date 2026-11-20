defmodule Pincer.Infra.ConfigTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Structs.Usage
  alias Pincer.Infra.Config

  describe "normalize_keys/1" do
    test "normalizes camelCase and atom keys to canonical snake_case strings recursively" do
      input = %{
        :gateway => %{
          "controlUi" => %{
            "allowInsecureAuth" => true,
            "dangerouslyDisableDeviceAuth" => false
          }
        },
        "hooks" => %{
          "mappings" => [
            %{"allowUnsafeExternalContent" => true}
          ]
        },
        "tools" => %{"restrictToWorkspace" => false}
      }

      assert Config.normalize_keys(input) == %{
               "gateway" => %{
                 "control_ui" => %{
                   "allow_insecure_auth" => true,
                   "dangerously_disable_device_auth" => false
                 }
               },
               "hooks" => %{
                 "mappings" => [
                   %{"allow_unsafe_external_content" => true}
                 ]
               },
               "tools" => %{"restrict_to_workspace" => false}
             }
    end

    test "preserves uppercase environment variable keys and structs" do
      usage = %Usage{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}

      input = %{
        "env" => %{
          "TELEGRAM_BOT_TOKEN" => "secret",
          "OPENAI_API_KEY" => "sk-123"
        },
        "usage" => usage
      }

      assert Config.normalize_keys(input) == %{
               "env" => %{
                 "TELEGRAM_BOT_TOKEN" => "secret",
                 "OPENAI_API_KEY" => "sk-123"
               },
               "usage" => usage
             }
    end

    test "canonical snake_case key takes precedence over camelCase alias deterministically" do
      input = %{
        "allowInsecureAuth" => false,
        "allow_insecure_auth" => true
      }

      assert Config.normalize_keys(input) == %{"allow_insecure_auth" => true}
    end
  end

  describe "load_file/1" do
    test "loads and normalizes camelCase YAML keys at the boundary" do
      tmp = tmp_dir!()
      path = Path.join(tmp, "config.yaml")

      File.write!(
        path,
        """
        gateway:
          controlUi:
            allowInsecureAuth: true
        tools:
          restrictToWorkspace: true
        """
      )

      assert {:ok, config} = Config.load_file(path)

      assert config == %{
               "gateway" => %{"control_ui" => %{"allow_insecure_auth" => true}},
               "tools" => %{"restrict_to_workspace" => true}
             }
    end

    test "returns :enoent when file does not exist" do
      assert {:error, :enoent} = Config.load_file("/nonexistent/pincer/config.yaml")
    end

    test "returns :invalid_root when YAML root is not a map" do
      tmp = tmp_dir!()
      path = Path.join(tmp, "list.yaml")
      File.write!(path, "- one\n- two\n")

      assert {:error, :invalid_root} = Config.load_file(path)
    end

    test "returns {:yaml_error, reason} when YAML is malformed" do
      tmp = tmp_dir!()
      path = Path.join(tmp, "bad.yaml")
      File.write!(path, "channels:\n  telegram: [")

      assert {:error, {:yaml_error, _reason}} = Config.load_file(path)
    end
  end

  defp tmp_dir! do
    tmp = Path.join(System.tmp_dir!(), "pincer_config_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    tmp
  end
end
