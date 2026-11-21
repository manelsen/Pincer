defmodule Pincer.Core.Executor.ToolRunner do
  @moduledoc """
  Executes sequential or parallel tool-call batches for `Pincer.Core.Executor`,
  handling approval handshakes, output truncation, consecutive-error tracking,
  workspace markdown notices, and trace accumulation via an explicit `%Ctx{}`.
  """

  require Logger

  alias Pincer.Core.AuditLog
  alias Pincer.Core.Executor.Ctx
  alias Pincer.Core.Executor.ToolCall
  alias Pincer.Core.Policy
  alias Pincer.Core.RBAC
  alias Pincer.Core.ToolRuntime
  alias Pincer.Infra.PubSub

  @approval_timeout_ms Application.compile_env(:pincer, :approval_timeout_ms, 600_000)
  @tool_result_max_chars Application.compile_env(:pincer, :tool_result_max_chars, 32_000)
  @consecutive_error_threshold 3

  @doc """
  Executes a batch of `tool_calls` under `ctx`, returning `{tool_messages, updated_ctx}`.
  """
  @spec execute_batch([term()], Ctx.t()) :: {[map()], Ctx.t()}
  def execute_batch(tool_calls, %Ctx{} = ctx) when is_list(tool_calls) do
    normalized = Enum.map(tool_calls, &normalize_call/1)
    send_session(ctx, {:sme_tool_use, Enum.map(normalized, &ToolCall.describe/1)})

    outcomes =
      if length(normalized) > 1 do
        names = ToolCall.names_summary(normalized)

        send_session(
          ctx,
          {:executor_status,
           "⚡ **Orquestração Paralela**: Executando #{length(normalized)} tarefas simultâneas (#{names})."}
        )

        run_parallel(normalized, ctx)
      else
        Enum.map(normalized, &execute_one(&1, ctx))
      end

    fold_outcomes(outcomes, ctx)
  end

  defp normalize_call(call) when is_map(call), do: ToolCall.ensure_type(call)
  defp normalize_call(other), do: other

  defp run_parallel(calls, %Ctx{} = ctx) do
    timeout = approval_timeout(ctx)
    stream_timeout = if timeout == :infinity, do: :infinity, else: timeout + 5_000

    Pincer.Core.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(calls, &execute_one(&1, ctx),
      max_concurrency: 10,
      timeout: stream_timeout,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, outcome} ->
        outcome

      {:exit, reason} ->
        {%{"role" => "tool", "content" => "Parallel execution error: #{inspect(reason)}"}, [],
         :ok}
    end)
  end

  defp fold_outcomes(outcomes, ctx) do
    {messages_rev, final_ctx} =
      Enum.reduce(outcomes, {[], ctx}, fn {msg, steps, status}, {msgs, acc_ctx} ->
        acc_ctx = Ctx.append_trace_steps(acc_ctx, steps)

        acc_ctx =
          case status do
            :ok ->
              Ctx.record_tool_outcome(acc_ctx, :ok)

            {:error, name, args, reason} ->
              updated = Ctx.record_tool_outcome(acc_ctx, :error)

              if updated.consecutive_errors >= @consecutive_error_threshold do
                Logger.warning(
                  "[SELF-IMPROVEMENT] Consecutive tool error detected. Capturing to Graph."
                )

                updated.deps.storage.save_tool_error(name, args, inspect(reason))
              end

              updated
          end

        {[msg | msgs], acc_ctx}
      end)

    {Enum.reverse(messages_rev), final_ctx}
  end

  defp execute_one(tool_call, %Ctx{} = ctx) when is_map(tool_call) do
    {call_id, name, raw_arguments} = ToolCall.normalize(tool_call)
    Logger.info("[TOOL] Executing #{name}")

    tool_class =
      case ToolRuntime.classify(name) do
        {:ok, class} -> class
        _ -> :privileged
      end

    steps =
      emit_live_step(ctx, [], :tool, "tool_invoked", %{
        tool: name,
        tool_call_id: call_id,
        class: tool_class
      })

    args = ToolCall.parse_arguments(raw_arguments)

    runtime_ctx = %{
      "session_id" => ctx.session_id,
      "workspace_path" => ctx.workspace_path,
      session_id: ctx.session_id,
      workspace_path: ctx.workspace_path
    }

    {result, steps, outcome} =
      run_tool(name, call_id, args, tool_class, runtime_ctx, ctx, steps)

    maybe_send_markdown_artifacts(ctx)
    content = format_tool_content(result)
    Logger.debug("[EXECUTOR] TOOL RESULT (#{name}): #{inspect(content)}")

    steps =
      emit_live_step(ctx, steps, :tool, "tool_result", %{
        tool: name,
        summary: ToolRuntime.sanitize_summary(name, content)
      })

    msg = %{"role" => "tool", "tool_call_id" => call_id, "name" => name, "content" => content}
    {msg, Enum.reverse(steps), outcome}
  end

  defp execute_one(_invalid_call, %Ctx{} = ctx) do
    steps = emit_live_step(ctx, [], :error, "tool_invalid_call", %{})

    msg = %{
      "role" => "tool",
      "tool_call_id" => "tool_call_invalid",
      "name" => "unknown_tool",
      "content" => "Error: invalid tool call payload."
    }

    {msg, Enum.reverse(steps), :ok}
  end

  defp run_tool(name, call_id, args, tool_class, runtime_ctx, ctx, steps) do
    registry = ctx.deps.tool_registry

    try do
      case ToolRuntime.execute(name, args, runtime_ctx, registry, approval_granted: false) do
        {:ok, content, _meta} ->
          steps = audit_step(ctx, steps, name, tool_class, :ok)
          {content, steps, :ok}

        {:error, {:approval_required, approval_data}, _meta} when is_map(approval_data) ->
          steps = audit_step(ctx, steps, name, tool_class, :approval_required)
          handle_approval(call_id, approval_data, runtime_ctx, ctx, steps)

        {:error, {:approval_required, cmd}, _meta} ->
          steps = audit_step(ctx, steps, name, tool_class, :approval_required)
          approval_data = %{tool: name, command: cmd, class: tool_class}
          handle_approval(call_id, approval_data, runtime_ctx, ctx, steps)

        {:error, :timeout, _meta} ->
          steps = audit_step(ctx, steps, name, tool_class, :timeout)

          {"Error: tool '#{name}' timed out and was cancelled.", steps,
           {:error, name, args, :timeout}}

        {:error, reason, _meta} ->
          steps = audit_step(ctx, steps, name, tool_class, :error)
          {"Error: #{inspect(reason)}", steps, {:error, name, args, reason}}
      end
    rescue
      e ->
        Logger.error("[TOOL] #{name} raised an exception: #{Exception.message(e)}")

        {"Error: tool '#{name}' raised an unexpected exception — #{Exception.message(e)}", steps,
         :ok}
    end
  end

  defp record_audit(ctx, tool_name, outcome, command) do
    AuditLog.record(:tool_approval, outcome,
      actor: ctx.session_id,
      target: tool_name,
      session_id: ctx.session_id,
      metadata: %{"command" => command}
    )
  end

  defp handle_approval(call_id, approval_data, runtime_ctx, ctx, steps) do
    if rbac_forbidden?(ctx) do
      handle_rbac_denial(approval_data, ctx, steps)
    else
      request_approval(call_id, approval_data, runtime_ctx, ctx, steps)
    end
  end

  defp rbac_forbidden?(ctx) do
    case RBAC.configured_role_for(ctx.session_id) do
      nil -> false
      role -> RBAC.authorize(role, :approve_tools) != :ok
    end
  end

  defp handle_rbac_denial(approval_data, ctx, steps) do
    tool_name = Map.get(approval_data, :tool) || Map.get(approval_data, "tool") || "safe_shell"

    Logger.warning("[EXECUTOR] RBAC denied tool approval for #{tool_name} (#{ctx.session_id})")

    record_audit(ctx, tool_name, :forbidden, nil)

    recovery =
      Policy.recover(:tool_approval_denied, %{
        tool: tool_name,
        class: :privileged,
        reason: :forbidden
      })

    {"Approval denied for #{tool_name}. Recovery: #{inspect(recovery)}", steps, :ok}
  end

  defp request_approval(call_id, approval_data, runtime_ctx, ctx, steps) do
    command = Map.get(approval_data, :command) || Map.get(approval_data, "command") || ""
    tool_name = Map.get(approval_data, :tool) || Map.get(approval_data, "tool") || "safe_shell"

    tool_args =
      Map.get(approval_data, :args) || Map.get(approval_data, "args") || %{"command" => command}

    tool_class = Map.get(approval_data, :class) || Map.get(approval_data, "class") || :privileged
    approval_prompt = build_approval_prompt(command, tool_name)

    Logger.warning("[EXECUTOR] Waiting for approval for: #{approval_prompt}")
    record_audit(ctx, tool_name, :approval_required, command)
    PubSub.broadcast("session:#{ctx.session_id}", {:approval_required, call_id, approval_prompt})

    receive do
      {:tool_approval_result, ^call_id, :approved} ->
        Logger.info("[EXECUTOR] Command approved: #{command}")
        steps = audit_step(ctx, steps, tool_name, tool_class, :approved)
        record_audit(ctx, tool_name, :approved, command)

        result =
          case ToolRuntime.execute(
                 tool_name,
                 tool_args,
                 runtime_ctx,
                 ctx.deps.tool_registry,
                 approval_granted: true,
                 class: tool_class
               ) do
            {:ok, res, _meta} -> res
            {:error, reason, _meta} -> "Error: #{inspect(reason)}"
          end

        {result, steps, :ok}

      {:tool_approval_result, ^call_id, :rejected} ->
        Logger.info("[EXECUTOR] Command rejected: #{command}")
        steps = audit_step(ctx, steps, tool_name, tool_class, :denied)
        record_audit(ctx, tool_name, :denied, command)

        recovery =
          Policy.recover(:tool_approval_denied, %{
            tool: tool_name,
            class: tool_class,
            reason: :user_denied
          })

        {"Approval denied for #{tool_name}. Recovery: #{inspect(recovery)}", steps, :ok}
    after
      approval_timeout(ctx) ->
        Logger.warning("[EXECUTOR] Approval timeout for: #{command}")
        {"Error: Command timed out waiting for approval.", steps, :ok}
    end
  end

  defp audit_step(ctx, steps, name, tool_class, status) do
    audit = Policy.guard!(:tool_audit_event, %{tool: name, class: tool_class, status: status})
    emit_live_step(ctx, steps, :tool, "tool_audit", audit)
  end

  defp emit_live_step(%Ctx{trace: nil}, steps, _kind, _name, _details), do: steps

  defp emit_live_step(%Ctx{session_pid: pid}, steps, kind, name, details) do
    if is_pid(pid), do: send(pid, {:executor_trace_step, kind, name, details})
    [{kind, name, details} | steps]
  end

  defp format_tool_content(parts) when is_list(parts), do: parts

  defp format_tool_content(result) do
    text = to_string(result)

    if String.length(text) > @tool_result_max_chars do
      String.slice(text, 0, @tool_result_max_chars) <>
        "\n[...resultado truncado — #{String.length(text)} chars originais]"
    else
      text
    end
  end

  defp maybe_send_markdown_artifacts(%Ctx{workspace_path: nil}), do: :ok

  defp maybe_send_markdown_artifacts(%Ctx{workspace_path: workspace_path} = ctx) do
    case File.ls(workspace_path) do
      {:ok, files} ->
        files
        |> Enum.filter(&(String.ends_with?(&1, ".md") and &1 != "BOOTSTRAP.md"))
        |> Enum.each(fn file ->
          case File.read(Path.join(workspace_path, file)) do
            {:ok, content} ->
              msg = "📝 **Artefato Atualizado**: `#{file}`\n\n#{truncate_markdown(content)}"
              send_session(ctx, {:executor_status, msg})

            _ ->
              :ok
          end
        end)

      _ ->
        :ok
    end
  end

  defp truncate_markdown(content) do
    if String.length(content) > 1000 do
      String.slice(content, 0, 1000) <> "\n\n[...conteúdo truncado]"
    else
      content
    end
  end

  defp build_approval_prompt(command, _tool_name)
       when is_binary(command) and command != "",
       do: command

  defp build_approval_prompt(_command, tool_name),
    do: "#{tool_name} (privileged tool requires approval)"

  defp approval_timeout(%Ctx{opts: opts}),
    do: Keyword.get(opts, :approval_timeout_ms, @approval_timeout_ms)

  defp send_session(%Ctx{session_pid: pid}, msg) when is_pid(pid) do
    send(pid, msg)
    :ok
  end

  defp send_session(_ctx, _msg), do: :ok
end
