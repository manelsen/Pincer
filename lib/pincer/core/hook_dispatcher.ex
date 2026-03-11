defmodule Pincer.Core.HookDispatcher do
  @moduledoc """
  Registry and dispatcher for lifecycle hook modules.

  `HookDispatcher` is a supervised GenServer that maintains an ETS table of
  registered hook modules. Each hook module implements `Pincer.Ports.Hook` and
  advertises the event it handles via `hook_name/0`.

  When `dispatch/2` is called, every module registered for that event name is
  invoked in registration order. Hooks that return `{:ok, new_context}` enrich
  the context for subsequent hooks. Hooks that return `{:error, reason}` emit a
  `Logger.warning/1` and pass the original context forward — they never abort
  the chain.

  ## Supervision

  `HookDispatcher` is started as a named process and should appear in the
  application supervision tree before any process that may dispatch events:

      children = [
        # ...
        Pincer.Core.HookDispatcher,
        Pincer.Core.Session.Supervisor,
        # ...
      ]

  ## Usage

      # Register a hook
      Pincer.Core.HookDispatcher.register(MyApp.Hooks.AuditLogger)

      # Dispatch a lifecycle event
      {:ok, enriched_context} =
        Pincer.Core.HookDispatcher.dispatch(:session_started, %{session_id: "abc"})

      # Remove a hook at runtime
      Pincer.Core.HookDispatcher.unregister(MyApp.Hooks.AuditLogger)

  ## ETS Layout

  The internal table `#{:pincer_hook_registry}` maps `hook_name()` atoms to
  ordered lists of `{position, module}` tuples, enabling FIFO dispatch.

  ## See Also

  - `Pincer.Ports.Hook` — Behaviour that hook modules must implement
  """
  use Boundary
  use GenServer
  require Logger

  @table :pincer_hook_registry

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the `HookDispatcher` process and initialises the ETS registry.

  Accepts the standard `GenServer` option list but requires no mandatory keys.
  The process is registered under its module name.

  ## Example

      {:ok, _pid} = Pincer.Core.HookDispatcher.start_link([])

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a module that implements `Pincer.Ports.Hook`.

  The module is appended to the list of hooks for its declared `hook_name/0`.
  Registering the same module twice is idempotent — duplicate entries are
  silently ignored.

  ## Parameters

    - `module` — An atom referring to a module that implements
                 `Pincer.Ports.Hook`.

  ## Examples

      :ok = Pincer.Core.HookDispatcher.register(MyApp.Hooks.Audit)

  """
  @spec register(module()) :: :ok
  def register(module) do
    GenServer.call(__MODULE__, {:register, module})
  end

  @doc """
  Removes a previously registered hook module.

  If the module is not currently registered, the call is a no-op.

  ## Parameters

    - `module` — The hook module to remove.

  ## Examples

      :ok = Pincer.Core.HookDispatcher.unregister(MyApp.Hooks.Audit)

  """
  @spec unregister(module()) :: :ok
  def unregister(module) do
    GenServer.call(__MODULE__, {:unregister, module})
  end

  @doc """
  Dispatches `event_name` to all hooks registered for that event.

  Hooks are called in registration order. Each hook receives the current
  `context` map. If a hook returns `{:ok, new_context}`, the updated context
  is passed to the next hook. If a hook returns `{:error, reason}`, a warning
  is logged and the unchanged context continues.

  Always returns `{:ok, context}` — dispatch never fails.

  ## Parameters

    - `event_name` — Atom identifying the lifecycle event (must match a
                     registered hook's `hook_name/0`).
    - `context` — Initial context map for the event.

  ## Examples

      {:ok, ctx} =
        Pincer.Core.HookDispatcher.dispatch(:session_started, %{session_id: "s1"})

  """
  @spec dispatch(atom(), map()) :: {:ok, map()}
  def dispatch(event_name, context) do
    modules = lookup_hooks(event_name)
    result = run_hooks(modules, event_name, context)
    {:ok, result}
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  @doc false
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :set,
      :protected,
      read_concurrency: true
    ])

    Logger.info("HookDispatcher started.")
    {:ok, %{}}
  end

  @impl true
  @doc false
  def handle_call({:register, module}, _from, state) do
    hook_name = module.hook_name()
    existing = lookup_hooks(hook_name)

    unless module in existing do
      :ets.insert(@table, {hook_name, existing ++ [module]})
    end

    {:reply, :ok, state}
  end

  @impl true
  @doc false
  def handle_call({:unregister, module}, _from, state) do
    hook_name = module.hook_name()
    existing = lookup_hooks(hook_name)
    updated = List.delete(existing, module)
    :ets.insert(@table, {hook_name, updated})
    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec lookup_hooks(atom()) :: [module()]
  defp lookup_hooks(event_name) do
    case :ets.lookup(@table, event_name) do
      [{^event_name, modules}] -> modules
      [] -> []
    end
  end

  @spec run_hooks([module()], atom(), map()) :: map()
  defp run_hooks([], _event_name, context), do: context

  defp run_hooks([module | rest], event_name, context) do
    case module.run(event_name, context) do
      {:ok, new_context} when is_map(new_context) ->
        run_hooks(rest, event_name, new_context)

      {:error, reason} ->
        Logger.warning(
          "HookDispatcher: hook #{inspect(module)} returned error for event " <>
            "#{inspect(event_name)}: #{inspect(reason)}"
        )

        run_hooks(rest, event_name, context)
    end
  end
end
