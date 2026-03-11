defmodule Pincer.Core.HookDispatcherTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.HookDispatcher

  # ---------------------------------------------------------------------------
  # Inline hook modules used across tests
  # ---------------------------------------------------------------------------

  defmodule OkHook do
    @moduledoc false
    @behaviour Pincer.Ports.Hook

    @impl true
    def hook_name, do: :test_event

    @impl true
    def run(:test_event, context) do
      {:ok, Map.put(context, :ok_hook_ran, true)}
    end
  end

  defmodule ErrorHook do
    @moduledoc false
    @behaviour Pincer.Ports.Hook

    @impl true
    def hook_name, do: :test_event

    @impl true
    def run(:test_event, _context) do
      {:error, :intentional_failure}
    end
  end

  defmodule SecondOkHook do
    @moduledoc false
    @behaviour Pincer.Ports.Hook

    @impl true
    def hook_name, do: :test_event

    @impl true
    def run(:test_event, context) do
      {:ok, Map.put(context, :second_hook_ran, true)}
    end
  end

  # ---------------------------------------------------------------------------
  # Setup: unregister any inline hooks after each test so state doesn't bleed
  # ---------------------------------------------------------------------------

  setup do
    on_exit(fn ->
      for mod <- [OkHook, ErrorHook, SecondOkHook] do
        # Only unregister if the process is alive (some tests may stop it)
        if Process.whereis(HookDispatcher) do
          HookDispatcher.unregister(mod)
        end
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "register/1 and dispatch/2" do
    test "registered hook is called and can enrich the context" do
      :ok = HookDispatcher.register(OkHook)

      {:ok, ctx} = HookDispatcher.dispatch(:test_event, %{initial: true})

      assert ctx[:ok_hook_ran] == true
      assert ctx[:initial] == true
    end

    test "registering the same module twice is idempotent" do
      :ok = HookDispatcher.register(OkHook)
      :ok = HookDispatcher.register(OkHook)

      # Only one run, so :ok_hook_ran should be true and context well-formed
      {:ok, ctx} = HookDispatcher.dispatch(:test_event, %{count: 0})

      assert ctx[:ok_hook_ran] == true
    end
  end

  describe "dispatch/2 with no hooks registered" do
    test "returns {:ok, context} unchanged when no hooks are registered for the event" do
      initial = %{some: :data}

      {:ok, ctx} = HookDispatcher.dispatch(:unknown_event_xyz, initial)

      assert ctx == initial
    end
  end

  describe "error isolation" do
    test "a hook returning {:error, reason} does not abort subsequent hooks" do
      :ok = HookDispatcher.register(ErrorHook)
      :ok = HookDispatcher.register(SecondOkHook)

      {:ok, ctx} =
        HookDispatcher.dispatch(:test_event, %{initial: true})

      # ErrorHook failed but SecondOkHook must still have run
      assert ctx[:second_hook_ran] == true
      # The initial context must be preserved despite the error
      assert ctx[:initial] == true
    end

    test "dispatch always returns {:ok, context} even when all hooks fail" do
      :ok = HookDispatcher.register(ErrorHook)

      result = HookDispatcher.dispatch(:test_event, %{safe: true})

      assert {:ok, %{safe: true}} = result
    end
  end

  describe "unregister/1" do
    test "unregistered hook is not called on subsequent dispatches" do
      :ok = HookDispatcher.register(OkHook)
      :ok = HookDispatcher.unregister(OkHook)

      {:ok, ctx} = HookDispatcher.dispatch(:test_event, %{initial: true})

      refute Map.has_key?(ctx, :ok_hook_ran)
    end

    test "unregistering a module that was never registered is a no-op" do
      assert :ok = HookDispatcher.unregister(OkHook)
    end
  end

  describe "ordering" do
    test "hooks are called in registration order and context flows through the chain" do
      :ok = HookDispatcher.register(OkHook)
      :ok = HookDispatcher.register(SecondOkHook)

      {:ok, ctx} = HookDispatcher.dispatch(:test_event, %{})

      assert ctx[:ok_hook_ran] == true
      assert ctx[:second_hook_ran] == true
    end
  end
end
