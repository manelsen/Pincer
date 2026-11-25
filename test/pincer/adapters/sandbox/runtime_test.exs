defmodule Pincer.Adapters.Sandbox.RuntimeTest do
  use ExUnit.Case, async: false

  alias Pincer.Adapters.Sandbox.Runtime

  describe "validate_env/1" do
    test "accepts nil, empty list, keyword-like tuples, and string maps" do
      assert {:ok, []} = Runtime.validate_env(nil)
      assert {:ok, []} = Runtime.validate_env([])

      assert {:ok, [{"FOO", "bar"}, {"BAZ_1", "qux"}]} =
               Runtime.validate_env([{"FOO", "bar"}, {"BAZ_1", "qux"}])

      assert {:ok, normalized} = Runtime.validate_env(%{"FOO_1" => "val", "BAR" => "2"})
      assert Enum.sort(normalized) == [{"BAR", "2"}, {"FOO_1", "val"}]
    end

    test "rejects dangerous loader and shell startup environment variables" do
      for forbidden <- [
            "LD_PRELOAD",
            "LD_LIBRARY_PATH",
            "LD_AUDIT",
            "LD_ORIGIN_PATH",
            "DYLD_INSERT_LIBRARIES",
            "DYLD_LIBRARY_PATH",
            "DYLD_FRAMEWORK_PATH",
            "DYLD_CUSTOM",
            "BASH_ENV",
            "ENV",
            "IFS"
          ] do
        assert {:error, {:forbidden_env, ^forbidden}} =
                 Runtime.validate_env([{forbidden, "/tmp/evil.so"}])
      end
    end

    test "rejects malformed variable names and non-binary entries" do
      for bad_key <- ["", "BAD-KEY", "123", "FOO=BAR", "a;b", "HAS SPACE"] do
        assert {:error, {:invalid_env_key, ^bad_key}} = Runtime.validate_env([{bad_key, "ok"}])
      end

      assert {:error, :invalid_env_entry} = Runtime.validate_env([{:ATOM_KEY, "val"}])
      assert {:error, :invalid_env_entry} = Runtime.validate_env([{"VALID_KEY", 123}])
      assert {:error, :invalid_env_entry} = Runtime.validate_env(["NOT_A_TUPLE"])
      assert {:error, :invalid_env_entry} = Runtime.validate_env(:invalid)
    end
  end

  describe "backend_config/1" do
    setup do
      previous_cfg = Application.get_env(:pincer, :sandbox)

      on_exit(fn ->
        if previous_cfg do
          Application.put_env(:pincer, :sandbox, previous_cfg)
        else
          Application.delete_env(:pincer, :sandbox)
        end
      end)

      :ok
    end

    test "reads configured backend options ignoring unknown string keys safely" do
      Application.put_env(:pincer, :sandbox, %{
        "docker" => %{"image" => "elixir:1.18", "nonexistent_atom_key_xyz_987" => "ignored"}
      })

      cfg = Runtime.backend_config(:docker)
      assert Keyword.get(cfg, :image) == "elixir:1.18"
      assert Runtime.backend_config(:ssh) == []
    end

    test "supports keyword list config under atom backend key" do
      Application.put_env(:pincer, :sandbox, %{local: [transport: :os, timeout_ms: 5_000]})

      cfg = Runtime.backend_config(:local)
      assert cfg == [transport: :os, timeout_ms: 5_000]
    end
  end

  describe "run_with_timeout/1,2" do
    test "executes function with default timeout, explicit timeout, and non-integer bypass" do
      assert {:ok, :default_done} = Runtime.run_with_timeout(fn -> :default_done end)
      assert {:ok, :done} = Runtime.run_with_timeout(fn -> :done end, 1_000)
      assert {:ok, :no_timer} = Runtime.run_with_timeout(fn -> :no_timer end, :infinity)
      assert {:ok, :zero_timeout} = Runtime.run_with_timeout(fn -> :zero_timeout end, 0)
    end

    test "enforces timeout and returns {:error, :timeout}" do
      assert {:error, :timeout} =
               Runtime.run_with_timeout(fn -> Process.sleep(200) end, 25)
    end
  end
end
