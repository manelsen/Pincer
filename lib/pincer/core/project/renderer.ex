defmodule Pincer.Core.Project.Renderer do
  @moduledoc """
  Pure markdown and Kanban board renderer for `Pincer.Core.ProjectOrchestrator`.
  """

  @default_max_items 6

  @doc "Renders the initialized project summary message after wizard completion."
  @spec render_ready_message(map()) :: String.t()
  def render_ready_message(state) when is_map(state) do
    coder_preview =
      state.items
      |> Enum.take(3)
      |> Enum.map_join("\n", fn item -> "- #{item.text}" end)

    reviewer_line =
      case state.kind do
        :software ->
          "Reviewer: aprovar somente com DDD/TDD explicito, testes verdes e contrato consistente."

        :non_software ->
          "Reviewer: aprovar somente com evidencias verificaveis e recomendacao comparativa clara."

        _ ->
          "Reviewer: validar coerencia do plano antes de execucao."
      end

    flow_line =
      case state.kind do
        :software -> "Flow: Architect -> Coder -> Reviewer (DDD/TDD ativo)"
        :non_software -> "Flow: Architect -> Coder -> Reviewer (Research/Validation)"
        _ -> "Flow: Architect -> Coder -> Reviewer"
      end

    """
    ✅ **Project plan initialized**
    Objective: #{state.objective}
    Type: #{kind_label(state.kind)}
    Scope: #{state.scope}
    Success: #{state.success_criteria}

    **Architect**
    - Escopo e contrato inicial definidos para execucao.

    **Coder**
    #{coder_preview}

    **Reviewer**
    - #{reviewer_line}

    #{git_summary(state)}

    #{flow_line}
    Use `/kanban` para visualizar o board desta sessao.
    """
    |> String.trim()
  end

  @doc "Renders the Kanban board for a ready project state."
  @spec render_board(map(), keyword()) :: String.t()
  def render_board(state, opts \\ []) when is_map(state) and is_list(opts) do
    max_items = opts |> Keyword.get(:max_items, @default_max_items) |> normalize_max_items()
    done = Enum.filter(state.items, &(&1.status == :done))
    in_progress = Enum.filter(state.items, &(&1.status == :in_progress))
    pending = Enum.filter(state.items, &(&1.status == :pending))

    flow =
      case state.kind do
        :software ->
          "Flow DDD/TDD\nSpec -> Contract -> Red -> Green -> Refactor -> Review -> Done"

        :non_software ->
          "Flow Research/Validation\nBrief -> Research -> Compare -> Validate -> Decide"

        _ ->
          "Flow\nArchitect -> Coder -> Reviewer"
      end

    [
      "Kanban Board",
      "Project: #{state.objective}",
      "Done: #{length(done)} | In Progress: #{length(in_progress)} | Pending: #{length(pending)}",
      "",
      "In Progress",
      format_items(in_progress, max_items),
      "",
      "Pending (Top #{max_items})",
      format_items(pending, max_items),
      "",
      "Done (Recent #{max_items})",
      format_items(Enum.reverse(done), max_items),
      "",
      flow
    ]
    |> Enum.join("\n")
    |> String.trim()
  end

  @doc "Renders the execution prompt dispatched to the agent for a project task."
  @spec build_task_prompt(map(), String.t()) :: String.t()
  def build_task_prompt(state, task) when is_map(state) and is_binary(task) do
    """
    PROJECT TASK
    Project ID: #{state.project_id}
    Phase: #{state.fsm_state.phase}
    Objective: #{state.objective}
    Task: #{task}
    """
    |> String.trim()
  end

  def build_task_prompt(state, _task) when is_map(state) do
    """
    PROJECT TASK
    Project ID: #{state.project_id}
    Phase: #{state.fsm_state.phase}
    Objective: #{state.objective}
    """
    |> String.trim()
  end

  @doc "Builds the progress payload map for execution lifecycle callbacks."
  @spec task_progress(atom(), map(), map()) :: map()
  def task_progress(:started, state, %{task: task}) do
    %{
      task: task,
      prompt: build_task_prompt(state, task),
      status_message: "Project Runner: Task started",
      phase: state.fsm_state.phase,
      project_id: state.project_id
    }
  end

  def task_progress(:next, state, %{completed: completed_task, task: next_task}) do
    %{
      completed: completed_task,
      task: next_task,
      prompt: build_task_prompt(state, next_task),
      status_message: "Project Runner: Next task started",
      phase: state.fsm_state.phase,
      project_id: state.project_id
    }
  end

  def task_progress(:completed, state, %{completed: completed_task}) do
    %{
      completed: completed_task,
      status_message: "Project Runner: All tasks completed",
      phase: state.fsm_state.phase,
      project_id: state.project_id
    }
  end

  def task_progress(:retry, state, %{task: task, attempt: attempt}) do
    %{
      task: task,
      prompt: build_task_prompt(state, task),
      status_message: "Project Runner: Task retrying (#{attempt}/#{state.retry_limit})",
      phase: state.fsm_state.phase,
      project_id: state.project_id
    }
  end

  def task_progress(:paused, state, %{task: task}) do
    %{
      task: task,
      status_message:
        "Project Runner: Task paused after #{state.retry_limit} retries. Use /project para retomar.",
      phase: state.fsm_state.phase,
      project_id: state.project_id
    }
  end

  @doc "Renders the Git branch preparation summary block."
  @spec git_summary(map()) :: String.t()
  def git_summary(%{git_branch: branch, git_branch_status: status})
      when is_binary(branch) and status in [:created, :existing] do
    status_label = if status == :created, do: "criada", else: "ja existente"

    """
    **Git Branch**
    - `#{branch}` (#{status_label}, sem checkout automatico)
    - Proximo passo: `git checkout #{branch}`
    """
    |> String.trim()
  end

  def git_summary(%{
        git_branch: branch,
        git_branch_status: {:error, {:not_a_repository, _detail}}
      })
      when is_binary(branch) do
    """
    **Git Branch**
    - Ambiente atual nao e um repositorio Git.
    - Inicialize com: `git init`
    - Depois crie manualmente: `git branch #{branch}`
    """
    |> String.trim()
  end

  def git_summary(%{git_branch: branch, git_branch_status: {:error, reason}})
      when is_binary(branch) do
    """
    **Git Branch**
    - Falha ao preparar branch automaticamente: #{format_branch_error(reason)}
    - Sugestao manual: `git branch #{branch}`
    """
    |> String.trim()
  end

  def git_summary(_state) do
    """
    **Git Branch**
    - Branch nao preparada automaticamente.
    """
    |> String.trim()
  end

  defp kind_label(:software), do: "software"
  defp kind_label(:non_software), do: "nao-software"
  defp kind_label(_), do: "indefinido"

  defp format_items(items, max_items) do
    items
    |> Enum.take(max_items)
    |> case do
      [] ->
        "- (none)"

      selected ->
        Enum.map_join(selected, "\n", fn item -> "- #{item.text}" end)
    end
  end

  defp normalize_max_items(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_items(_), do: @default_max_items

  defp format_branch_error({:branch_create_failed, detail}) when is_binary(detail), do: detail
  defp format_branch_error({:git_unavailable, detail}) when is_binary(detail), do: detail
  defp format_branch_error(other), do: inspect(other)
end
