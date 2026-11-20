defmodule Pincer.Contracts.SandboxAdapterContractTest do
  @moduledoc """
  Contract tests verifying that all sandbox adapters implement `Pincer.Ports.Sandbox`.
  """
  use ExUnit.Case, async: true

  @sandbox_adapters [
    Pincer.Adapters.Sandbox.Local,
    Pincer.Adapters.Sandbox.Docker,
    Pincer.Adapters.Sandbox.SSH
  ]

  @required_callbacks [
    {:backend_name, 0},
    {:available?, 0},
    {:run, 2},
    {:cleanup, 1}
  ]

  test "sandbox adapters declare Pincer.Ports.Sandbox behaviour" do
    Enum.each(@sandbox_adapters, fn adapter_module ->
      Code.ensure_loaded!(adapter_module)
      behaviours = adapter_module.module_info(:attributes)[:behaviour] || []

      assert Pincer.Ports.Sandbox in behaviours,
             "#{inspect(adapter_module)} must declare @behaviour Pincer.Ports.Sandbox"
    end)
  end

  test "sandbox adapters export required callbacks" do
    Enum.each(@sandbox_adapters, fn adapter_module ->
      Code.ensure_loaded!(adapter_module)

      Enum.each(@required_callbacks, fn {fun, arity} ->
        assert function_exported?(adapter_module, fun, arity),
               "#{inspect(adapter_module)} must export #{fun}/#{arity}"
      end)
    end)
  end
end
