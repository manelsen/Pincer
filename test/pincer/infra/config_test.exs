defmodule Pincer.Infra.ConfigTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Structs.Usage
  alias Pincer.Infra.Config

  setup do
    keys = [
      :sandbox,
      :sandbox_adapter,
      :storage_adapter,
      :sqlite_path,
      :database,
      :storage,
      :repo,
      :llm,
      :default_llm_provider,
      :introspection,
      :model_router,
      :tokens,
      :channels,
      :gateway,
      :tools
    ]

    snapshot = Map.new(keys, fn k -> {k, Application.get_env(:pincer, k, :__unset__)} end)
    prev_sandbox_env = System.get_env("PINCER_SANDBOX_ADAPTER")
    prev_storage_env = System.get_env("PINCER_STORAGE")
    prev_sqlite_env = System.get_env("PINCER_SQLITE_PATH")

    on_exit(fn ->
      Enum.each(snapshot, fn
        {k, :__unset__} -> Application.delete_env(:pincer, k)
        {k, v} -> Application.put_env(:pincer, k, v)
      end)

      restore_sys_env("PINCER_SANDBOX_ADAPTER", prev_sandbox_env)
      restore_sys_env("PINCER_STORAGE", prev_storage_env)
      restore_sys_env("PINCER_SQLITE_PATH", prev_sqlite_env)
    end)

    :ok
  end

  defp restore_sys_env(key, nil), do: System.delete_env(key)
  defp restore_sys_env(key, val), do: System.put_env(key, val)

  defp tmp_dir! do
    tmp = Path.join(System.tmp_dir!(), "pincer_config_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    tmp
  end

  defp write_yaml!(content) do
    path = Path.join(System.tmp_dir!(), "pincer_cfg_#{System.unique_integer([:positive])}.yaml")
    File.write!(path, content)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

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

  describe "sandbox config" do
    test "loads sandbox backend and per-backend options from config yaml" do
      yaml =
        write_yaml!("""
        sandbox:
          adapter: "docker"
          docker:
            image: "elixir:1.18-alpine"
            network: "none"
        """)

      System.delete_env("PINCER_SANDBOX_ADAPTER")
      assert :ok = Config.load(config_file: yaml, load_dotenv: false)

      assert Application.get_env(:pincer, :sandbox_adapter) == Pincer.Adapters.Sandbox.Docker

      assert %{"adapter" => "docker", "docker" => %{"image" => "elixir:1.18-alpine"}} =
               Config.get(:sandbox)
    end

    test "PINCER_SANDBOX_ADAPTER overrides config.yaml sandbox adapter" do
      yaml =
        write_yaml!("""
        sandbox:
          adapter: "local"
        """)

      System.put_env("PINCER_SANDBOX_ADAPTER", "ssh")
      assert :ok = Config.load(config_file: yaml, load_dotenv: false)

      assert Application.get_env(:pincer, :sandbox_adapter) == Pincer.Adapters.Sandbox.SSH
    end
  end

  describe "sqlite storage config" do
    test "configures Pincer.Storage.Adapters.SQLite via database.adapter and database.path" do
      yaml =
        write_yaml!("""
        database:
          adapter: "sqlite"
          path: "tmp/test_zero_infra.db"
        """)

      System.delete_env("PINCER_STORAGE")
      System.delete_env("PINCER_SQLITE_PATH")
      assert :ok = Config.load(config_file: yaml, load_dotenv: false)

      assert Application.get_env(:pincer, :storage_adapter) == Pincer.Storage.Adapters.SQLite
      assert Application.get_env(:pincer, :sqlite_path) == "tmp/test_zero_infra.db"
    end

    test "supports storage.adapter and PINCER_STORAGE / PINCER_SQLITE_PATH overrides" do
      yaml =
        write_yaml!("""
        database:
          adapter: "Ecto.Adapters.PostgreSQL"
          hostname: "localhost"
        """)

      System.put_env("PINCER_STORAGE", "sqlite")
      System.put_env("PINCER_SQLITE_PATH", "/tmp/pincer_override.db")
      assert :ok = Config.load(config_file: yaml, load_dotenv: false)

      assert Application.get_env(:pincer, :storage_adapter) == Pincer.Storage.Adapters.SQLite
      assert Application.get_env(:pincer, :sqlite_path) == "/tmp/pincer_override.db"
    end
  end
end
