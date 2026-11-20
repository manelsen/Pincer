defmodule Pincer.Core.RegistryTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Registry, as: CoreRegistry

  describe "child_spec/1" do
    test "raises KeyError when :name is missing" do
      assert_raise KeyError, fn ->
        CoreRegistry.child_spec([])
      end
    end

    test "raises ArgumentError when :backend is unsupported" do
      assert_raise ArgumentError, fn ->
        CoreRegistry.child_spec(name: :bad_reg, backend: :pg2)
      end
    end

    test "builds child_specs for both :local and :horde backends" do
      local_spec = CoreRegistry.child_spec(name: :test_local_spec, backend: :local)
      assert local_spec.id == :test_local_spec

      horde_spec = CoreRegistry.child_spec(name: :test_horde_spec, backend: :horde)
      assert horde_spec.id == :test_horde_spec
    end
  end

  describe "via_tuple/3 and lookup/3" do
    test "registers and looks up processes on :local backend" do
      name = :"test_local_reg_#{System.unique_integer([:positive])}"
      start_supervised!({CoreRegistry, name: name, backend: :local})

      via = CoreRegistry.via_tuple(name, "key-1", :local)
      assert {:via, Registry, {^name, "key-1"}} = via

      {:ok, pid} = Agent.start_link(fn -> :ok end, name: via)
      assert [{^pid, _}] = CoreRegistry.lookup(name, "key-1", :local)
      assert [] = CoreRegistry.lookup(name, "missing", :local)
    end

    test "registers and looks up processes on :horde backend (default)" do
      name = :"test_horde_reg_#{System.unique_integer([:positive])}"
      start_supervised!({CoreRegistry, name: name, backend: :horde})

      via = CoreRegistry.via_tuple(name, "key-2")
      assert {:via, Horde.Registry, {^name, "key-2"}} = via

      {:ok, pid} = Agent.start_link(fn -> :ok end, name: via)
      assert [{^pid, _}] = CoreRegistry.lookup(name, "key-2")
      assert [] = CoreRegistry.lookup(name, "missing")
    end

    test "raises ArgumentError for unknown backend in via_tuple/lookup" do
      assert_raise ArgumentError, fn ->
        CoreRegistry.via_tuple(:some_reg, "k", :unknown)
      end

      assert_raise ArgumentError, fn ->
        CoreRegistry.lookup(:some_reg, "k", :unknown)
      end
    end
  end
end
