defmodule Pincer.Ports.Hook do
  @moduledoc """
  Behaviour for lifecycle hooks in Pincer.

  Hooks allow external modules to observe and enrich lifecycle events without
  coupling directly to core logic. Any module implementing this behaviour can
  be registered with `Pincer.Core.HookDispatcher` to be called when a named
  event is dispatched.

  ## The Hook Contract

  A hook must implement two callbacks:

  1. `hook_name/0` — Returns the atom identifying which event this hook handles.
  2. `run/2` — Called with the event name and a context map when the event fires.

  ## Context Enrichment

  Hooks that return `{:ok, new_context}` replace the running context for the
  subsequent hooks in the chain. Hooks that return `{:error, reason}` are logged
  as warnings but do not abort the chain; the original context is preserved and
  passed to the next hook.

  ## Example

      defmodule MyApp.Hooks.AuditLogger do
        @behaviour Pincer.Ports.Hook

        @impl true
        def hook_name, do: :session_started

        @impl true
        def run(:session_started, context) do
          MyApp.Audit.log("Session started", context)
          {:ok, context}
        end
      end

  ## Registration

  Register hooks at runtime via:

      Pincer.Core.HookDispatcher.register(MyApp.Hooks.AuditLogger)

  Or unregister when no longer needed:

      Pincer.Core.HookDispatcher.unregister(MyApp.Hooks.AuditLogger)

  ## See Also

  - `Pincer.Core.HookDispatcher` — Registry and dispatcher for hook modules
  """
  use Boundary

  @doc """
  Returns the atom name of the lifecycle event this hook handles.

  The dispatcher uses this to route events to the correct set of hooks.
  Hook names should be descriptive atoms like `:session_started`,
  `:tool_called`, or `:message_received`.

  ## Example

      @impl true
      def hook_name, do: :session_started

  """
  @callback hook_name() :: atom()

  @doc """
  Runs the hook for the given event and context.

  Called by `Pincer.Core.HookDispatcher.dispatch/2` for every registered hook
  that matches the dispatched `event_name`. The `context` map carries arbitrary
  data associated with the event.

  ## Parameters

    - `event_name` — The atom identifying the lifecycle event being dispatched.
    - `context` — A map with event-specific data. May be enriched by returning
                  `{:ok, new_context}`.

  ## Return Values

    - `{:ok, context}` — Hook completed. The (possibly updated) context is
                         forwarded to subsequent hooks.
    - `{:error, reason}` — Hook failed. The error is logged as a warning and
                           the original context continues to the next hook.

  ## Example

      @impl true
      def run(:session_started, context) do
        {:ok, Map.put(context, :audit_ts, DateTime.utc_now())}
      end

  """
  @callback run(event_name :: atom(), context :: map()) :: {:ok, map()} | {:error, term()}
end
