defmodule Pincer.Core.Executor.Ctx do
  @moduledoc """
  Explicit, immutable execution context threaded through `Pincer.Core.Executor`
  and its collaborators, replacing process-dictionary dependency injection.
  """

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Executor.Attachments
  alias Pincer.Core.Trace

  @default_max_recursion_depth 100

  @type deps :: %{
          llm_client: module(),
          tool_registry: module(),
          storage: module(),
          file_fetcher: (String.t() -> {:ok, String.t()} | {:error, term()}),
          max_depth: pos_integer()
        }

  @type model_override :: %{
          required(:provider) => String.t(),
          required(:model) => String.t(),
          optional(:thinking_level) => String.t()
        }

  defstruct [
    :session_pid,
    :session_id,
    :ref,
    :workspace_path,
    :deps,
    :model_override,
    :trace,
    :context_strategy,
    consecutive_errors: 0,
    long_term_memory: "",
    opts: []
  ]

  @type t :: %__MODULE__{
          session_pid: pid() | nil,
          session_id: String.t(),
          ref: reference() | nil,
          workspace_path: String.t(),
          deps: deps(),
          model_override: model_override() | nil,
          trace: Trace.t() | nil,
          context_strategy: atom() | nil,
          consecutive_errors: non_neg_integer(),
          long_term_memory: String.t(),
          opts: keyword()
        }

  @doc """
  Builds a new `%Ctx{}` from executor arguments and options, resolving runtime
  dependencies and normalizing `model_override` once at the boundary.
  """
  @spec new(pid() | nil, String.t(), keyword()) :: t()
  def new(session_pid, session_id, opts \\ []) when is_binary(session_id) and is_list(opts) do
    max_depth =
      opts[:max_depth] ||
        Application.get_env(:pincer, :max_recursion_depth, @default_max_recursion_depth)

    deps = %{
      llm_client: opts[:llm_client] || Pincer.Ports.LLM,
      tool_registry: opts[:tool_registry] || Pincer.Ports.ToolRegistry,
      storage: opts[:storage] || Pincer.Ports.Storage,
      file_fetcher: opts[:file_fetcher] || (&Attachments.default_fetch/1),
      max_depth: max_depth
    }

    trace =
      if Keyword.get(opts, :trace_events?, false) do
        Trace.new(session_id, "turn-#{System.unique_integer([:positive])}", %{
          depth_limit: max_depth
        })
      end

    %__MODULE__{
      session_pid: session_pid,
      session_id: session_id,
      ref: Keyword.get(opts, :ref),
      workspace_path: opts[:workspace_path] || AgentPaths.workspace_root(session_id),
      deps: deps,
      model_override: normalize_model_override(opts[:model_override]),
      trace: trace,
      context_strategy: Keyword.get(opts, :context_strategy),
      long_term_memory: Keyword.get(opts, :long_term_memory, ""),
      opts: opts
    }
  end

  @doc """
  Updates the normalized `model_override` mid-turn (e.g., on `:model_changed`).
  """
  @spec with_model_override(t(), String.t(), String.t()) :: t()
  def with_model_override(%__MODULE__{} = ctx, provider, model)
      when is_binary(provider) and is_binary(model) do
    %{ctx | model_override: %{provider: provider, model: model}}
  end

  @doc """
  Extracts keyword options expected by `Pincer.Ports.LLM` from `ctx.model_override`.
  """
  @spec client_opts(t()) :: keyword()
  def client_opts(%__MODULE__{model_override: nil}), do: []

  def client_opts(%__MODULE__{model_override: %{provider: provider, model: model} = override}) do
    base = [provider: provider, model: model]

    case Map.get(override, :thinking_level) do
      nil -> base
      thinking -> Keyword.put(base, :thinking_level, thinking)
    end
  end

  @doc """
  Resolves the active LLM provider name for `ctx`.
  """
  @spec active_provider(t()) :: String.t()
  def active_provider(%__MODULE__{model_override: %{provider: provider}})
      when is_binary(provider) and provider != "",
      do: provider

  def active_provider(%__MODULE__{}) do
    llm_cfg = Pincer.Infra.Config.get(:llm) || %{}

    Application.get_env(:pincer, :default_llm_provider) ||
      Map.get(llm_cfg, "provider") ||
      "openrouter"
  end

  @doc """
  Appends a trace step and emits `{:executor_trace_step, ...}` to `session_pid`
  when tracing is enabled.
  """
  @spec record_trace(t(), atom(), String.t(), map()) :: t()
  def record_trace(%__MODULE__{trace: nil} = ctx, _kind, _name, _details), do: ctx

  def record_trace(%__MODULE__{trace: trace} = ctx, kind, name, details)
      when is_atom(kind) and is_binary(name) and is_map(details) do
    updated = Trace.add_step(trace, kind, name, details)

    if is_pid(ctx.session_pid) do
      send(ctx.session_pid, {:executor_trace_step, kind, name, details})
    end

    %{ctx | trace: updated}
  end

  @doc """
  Folds already-emitted `{kind, name, details}` steps (e.g., from parallel tool tasks)
  into `ctx.trace` without re-sending live events.
  """
  @spec append_trace_steps(t(), [{atom(), String.t(), map()}]) :: t()
  def append_trace_steps(%__MODULE__{trace: nil} = ctx, _steps), do: ctx

  def append_trace_steps(%__MODULE__{trace: trace} = ctx, steps) when is_list(steps) do
    updated =
      Enum.reduce(steps, trace, fn {kind, name, details}, acc ->
        Trace.add_step(acc, kind, name, details)
      end)

    %{ctx | trace: updated}
  end

  @doc """
  Sends the final `{:executor_trace, metadata}` checkpoint snapshot when tracing is enabled.
  """
  @spec emit_trace_snapshot(t()) :: :ok
  def emit_trace_snapshot(%__MODULE__{trace: nil}), do: :ok

  def emit_trace_snapshot(%__MODULE__{trace: trace, session_pid: pid}) when is_pid(pid) do
    send(pid, {:executor_trace, Trace.to_checkpoint_metadata(trace)})
    :ok
  end

  def emit_trace_snapshot(%__MODULE__{}), do: :ok

  @doc """
  Updates the consecutive tool error counter.
  """
  @spec record_tool_outcome(t(), :ok | :error) :: t()
  def record_tool_outcome(%__MODULE__{} = ctx, :ok), do: %{ctx | consecutive_errors: 0}

  def record_tool_outcome(%__MODULE__{} = ctx, :error),
    do: %{ctx | consecutive_errors: ctx.consecutive_errors + 1}

  defp normalize_model_override(nil), do: nil

  defp normalize_model_override(override) when is_map(override) do
    provider = override[:provider] || override["provider"]
    model = override[:model] || override["model"]
    thinking = override[:thinking_level] || override["thinking_level"]

    if is_binary(provider) and provider != "" and is_binary(model) and model != "" do
      base = %{provider: provider, model: model}
      if thinking, do: Map.put(base, :thinking_level, thinking), else: base
    else
      nil
    end
  end

  defp normalize_model_override(_), do: nil
end
