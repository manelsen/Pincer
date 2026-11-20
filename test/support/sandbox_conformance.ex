defmodule Pincer.Test.Support.SandboxConformance do
  @moduledoc """
  Shared ExUnit conformance tests for `Pincer.Ports.Sandbox` adapters.

  Inspired by Nous Research Hermes Agent's `tools/environments/sandbox_conformance.py`.
  Each adapter `use`s this module with `adapter: MyAdapter` and implements a
  `conformance_run_opts/1` helper returning adapter-specific options for a safe test run.
  """

  defmacro __using__(opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    expected_backend = Keyword.fetch!(opts, :backend)

    quote do
      @conformance_adapter unquote(adapter)
      @expected_backend unquote(expected_backend)

      describe "SandboxConformance" do
        test "declares Pincer.Ports.Sandbox behaviour and exports callbacks" do
          behaviours = @conformance_adapter.module_info(:attributes)[:behaviour] || []
          assert Pincer.Ports.Sandbox in behaviours
          assert function_exported?(@conformance_adapter, :backend_name, 0)
          assert function_exported?(@conformance_adapter, :available?, 0)
          assert function_exported?(@conformance_adapter, :run, 2)
          assert function_exported?(@conformance_adapter, :cleanup, 1)
          assert @conformance_adapter.backend_name() == @expected_backend
          assert is_boolean(@conformance_adapter.available?())
        end

        test "rejects forbidden loader environment variables" do
          workspace =
            Path.join(System.tmp_dir!(), "sbx_conf_#{System.unique_integer([:positive])}")

          File.mkdir_p!(workspace)
          on_exit(fn -> File.rm_rf(workspace) end)

          base_opts = conformance_run_opts(workspace)
          opts = Keyword.put(base_opts, :env, [{"LD_PRELOAD", "/tmp/evil.so"}])

          assert {:error, {:forbidden_env, "LD_PRELOAD"}} =
                   @conformance_adapter.run("echo hi", opts)
        end

        test "rejects workspace escape attempts when workspace_path is enforced" do
          workspace =
            Path.join(System.tmp_dir!(), "sbx_conf_#{System.unique_integer([:positive])}")

          File.mkdir_p!(workspace)
          on_exit(fn -> File.rm_rf(workspace) end)

          base_opts = conformance_run_opts(workspace)

          opts =
            base_opts
            |> Keyword.put(:workspace_path, workspace)
            |> Keyword.put(:cwd, Path.expand("../outside", workspace))
            |> Keyword.put(:restrict_to_workspace, true)

          assert {:error, _reason} = @conformance_adapter.run("pwd", opts)
        end

        test "returns normalized run_result map on execution" do
          workspace =
            Path.join(System.tmp_dir!(), "sbx_conf_#{System.unique_integer([:positive])}")

          File.mkdir_p!(workspace)
          on_exit(fn -> File.rm_rf(workspace) end)

          opts = conformance_run_opts(workspace)

          assert {:ok, result} = @conformance_adapter.run("echo conformance-ok", opts)
          assert is_binary(result.output)
          assert is_integer(result.exit_code)
          assert result.backend == @expected_backend
          assert is_map(result.metadata)
        end

        test "cleanup/1 succeeds cleanly for unknown scope" do
          assert :ok =
                   @conformance_adapter.cleanup(
                     "nonexistent-scope-#{System.unique_integer([:positive])}"
                   )
        end
      end
    end
  end
end
