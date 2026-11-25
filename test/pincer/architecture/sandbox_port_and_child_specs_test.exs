defmodule Pincer.Architecture.SandboxPortAndChildSpecsTest do
  use ExUnit.Case, async: true

  @documented_registered_names MapSet.new([
                                 Pincer.ClusterSupervisor,
                                 Pincer.Core.Orchestration.SubAgentSupervisor,
                                 Pincer.Finch,
                                 Pincer.Dispatcher.Registry,
                                 Pincer.TaskSupervisor,
                                 Pincer.MCP.Supervisor,
                                 Pincer.Core.Introspection.Kernel.Registry,
                                 Pincer.Core.TaskSupervisor,
                                 Pincer.Core.Session.Registry,
                                 Pincer.Core.Session.HordeRegistry,
                                 Pincer.Core.Project.HordeRegistry,
                                 Pincer.Core.Project.Registry
                               ])

  describe "Pincer.Ports.Sandbox purity" do
    test "does not export runtime or policy helpers" do
      assert Code.ensure_loaded?(Pincer.Ports.Sandbox)

      for {fun, arity} <- [
            {:run_with_timeout, 1},
            {:run_with_timeout, 2},
            {:validate_env, 1},
            {:backend_config, 1}
          ] do
        refute function_exported?(Pincer.Ports.Sandbox, fun, arity),
               "Pincer.Ports.Sandbox must not export #{fun}/#{arity}"
      end
    end

    test "lib/pincer/ports/sandbox.ex contains no Task calls" do
      source = File.read!("lib/pincer/ports/sandbox.ex")

      refute source =~ ~r/\bTask\./,
             "lib/pincer/ports/sandbox.ex must not call Task.* directly"
    end
  end

  describe "Pincer.Application.child_specs/0,1" do
    test "default child_specs returns valid loaded child specs with documented registered names" do
      specs = Pincer.Application.child_specs()
      validate_specs!(specs)
    end

    test "child_specs(enable_browser: true, env: :dev) includes optional children and validates all specs" do
      specs = Pincer.Application.child_specs(enable_browser: true, env: :dev)

      assert Pincer.Adapters.Browser.Pool in specs
      assert Pincer.Core.Reloader in specs

      validate_specs!(specs)
    end

    test "child_specs(enable_browser: false, env: :test) omits optional browser and reloader children" do
      specs = Pincer.Application.child_specs(enable_browser: false, env: :test)

      refute Pincer.Adapters.Browser.Pool in specs
      refute Pincer.Core.Reloader in specs
    end
  end

  defp validate_specs!(specs) do
    names =
      Enum.flat_map(specs, fn spec ->
        mod = resolve_child_module!(spec)

        assert Code.ensure_loaded?(mod),
               "Expected child module #{inspect(mod)} to be loaded"

        assert function_exported?(mod, :child_spec, 1),
               "Expected child module #{inspect(mod)} to export child_spec/1"

        normalized = Supervisor.child_spec(spec, [])
        assert %{start: {start_mod, start_fun, start_args}} = normalized

        assert Code.ensure_loaded?(start_mod),
               "Expected start module #{inspect(start_mod)} for #{inspect(spec)} to be loaded"

        assert function_exported?(start_mod, start_fun, length(start_args)),
               "Expected #{inspect(start_mod)}.#{start_fun}/#{length(start_args)} to be exported"

        extract_names(spec)
      end)

    assert names != []

    assert length(names) == length(Enum.uniq(names)),
           "Duplicate registered names: #{inspect(names)}"

    for name <- names do
      assert MapSet.member?(@documented_registered_names, name),
             "Unexpected registered child :name #{inspect(name)} (not in documented set)"
    end

    assert MapSet.equal?(MapSet.new(names), @documented_registered_names)
  end

  defp resolve_child_module!(mod) when is_atom(mod), do: mod
  defp resolve_child_module!({mod, _arg}) when is_atom(mod), do: mod
  defp resolve_child_module!(%{start: {mod, _fun, _args}}) when is_atom(mod), do: mod

  defp extract_names({_mod, arg}), do: extract_names_from_term(arg)
  defp extract_names(_other), do: []

  defp extract_names_from_term(list) when is_list(list) do
    Enum.flat_map(list, fn
      {:name, name} when is_atom(name) -> [name]
      nested when is_list(nested) -> extract_names_from_term(nested)
      _other -> []
    end)
  end

  defp extract_names_from_term(_other), do: []
end
