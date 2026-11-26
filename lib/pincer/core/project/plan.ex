defmodule Pincer.Core.Project.Plan do
  @moduledoc """
  Project plan item creation, Git branch provisioning (`Pincer.Ports.Git`), and
  task execution/retry state transitions.
  """

  alias Pincer.Core.Project.Wizard
  alias Pincer.Ports.Git

  @default_retry_limit 0

  @type item_status :: :pending | :in_progress | :done
  @type item :: %{status: item_status(), text: String.t()}

  @doc "Builds deterministic plan items for the given project state."
  @spec build_items(map()) :: [item()]
  def build_items(%{kind: :software, objective: objective, scope: scope}) do
    [
      pending("Architect: definir linguagem ubiqua e limites de dominio para '#{objective}'"),
      pending("Architect: consolidar contrato inicial no SPECS.md com escopo '#{scope}'"),
      pending("Coder: Red - escrever teste que falha para o primeiro incremento"),
      pending("Coder: Green - implementar o minimo para o teste passar"),
      pending("Coder: Refactor - simplificar mantendo testes verdes"),
      pending("Reviewer: validar cobertura (caminho feliz + erro) e criterio de aceite")
    ]
  end

  def build_items(%{kind: :non_software, objective: objective, scope: scope}) do
    [
      pending("Architect: definir criterio objetivo para '#{objective}'"),
      pending("Coder: pesquisar opcoes reais dentro do escopo '#{scope}'"),
      pending("Coder: comparar custo-beneficio, disponibilidade e riscos"),
      pending("Reviewer: validar fonte e data de cada evidencia"),
      pending("Reviewer: propor recomendacao final com trade-offs")
    ]
  end

  def build_items(_state), do: []

  @doc "Prepares items, Git branch, and retry defaults for plan finalization."
  @spec prepare(map(), String.t(), keyword()) :: {map(), map()}
  def prepare(state, success_criteria, opts \\ [])
      when is_map(state) and is_binary(success_criteria) and is_list(opts) do
    items = build_items(state)
    limit = Keyword.get(opts, :retry_limit, retry_limit())

    prepared =
      state
      |> Map.put(:success_criteria, success_criteria)
      |> Map.put(:items, items)
      |> ensure_project_branch(opts)
      |> Map.put(:retry_count, 0)
      |> Map.put(:retry_limit, limit)

    plan_payload = %{
      kind: prepared.kind,
      success_criteria: success_criteria,
      items: items
    }

    {prepared, plan_payload}
  end

  @doc "Ensures a dedicated Git branch exists for the project via `Pincer.Ports.Git`."
  @spec ensure_project_branch(map(), keyword()) :: map()
  def ensure_project_branch(state, opts \\ [])

  def ensure_project_branch(%{git_branch: branch} = state, _opts)
      when is_binary(branch) and branch != "" do
    state
  end

  def ensure_project_branch(state, opts) when is_map(state) and is_list(opts) do
    branch_name = build_branch_name(state)
    adapter = git_adapter(opts)

    case adapter.ensure_branch(branch_name) do
      {:ok, %{status: status}} when status in [:created, :existing] ->
        %{state | git_branch: branch_name, git_branch_status: status}

      {:ok, :created} ->
        %{state | git_branch: branch_name, git_branch_status: :created}

      {:ok, :existing} ->
        %{state | git_branch: branch_name, git_branch_status: :existing}

      {:error, reason} ->
        %{state | git_branch: branch_name, git_branch_status: {:error, reason}}
    end
  end

  @doc "Starts the first pending task if the plan is ready and idle."
  @spec start_next_task(map()) ::
          :not_ready | :already_started | :completed | {:started, map(), String.t()}
  def start_next_task(state) when is_map(state) do
    if Wizard.phase(state) == :ready do
      cond do
        Enum.any?(state.items, &(&1.status == :in_progress)) ->
          :already_started

        Enum.any?(state.items, &(&1.status == :pending)) ->
          {next_state, task} = mark_first_pending_in_progress(state)
          {:started, %{next_state | retry_count: 0}, task}

        true ->
          :completed
      end
    else
      :not_ready
    end
  end

  @doc "Marks the active task done and starts the next pending task if available."
  @spec complete_current_task(map()) ::
          :noop | {:next, map(), String.t(), String.t()} | {:all_done, map(), String.t()}
  def complete_current_task(state) when is_map(state) do
    if Wizard.phase(state) == :ready do
      case complete_in_progress_item(state) do
        {:ok, updated, completed_task} ->
          if Enum.any?(updated.items, &(&1.status == :pending)) do
            {next_state, next_task} = mark_first_pending_in_progress(updated)
            {:next, %{next_state | retry_count: 0}, completed_task, next_task}
          else
            {:all_done, %{updated | retry_count: 0}, completed_task}
          end

        :noop ->
          :noop
      end
    else
      :noop
    end
  end

  @doc "Applies retry or pause transition when the active task fails."
  @spec fail_current_task(map()) ::
          :noop
          | {:retry, map(), String.t(), pos_integer()}
          | {:paused, map(), String.t()}
  def fail_current_task(state) when is_map(state) do
    if Wizard.phase(state) == :ready do
      case current_in_progress_task(state.items) do
        nil ->
          :noop

        task ->
          if state.retry_count < state.retry_limit do
            next_retry = state.retry_count + 1
            {:retry, %{state | retry_count: next_retry}, task, next_retry}
          else
            paused = pause_in_progress_item(state)
            {:paused, %{paused | retry_count: state.retry_limit}, task}
          end
      end
    else
      :noop
    end
  end

  @doc "Returns the configured per-task retry limit."
  @spec retry_limit() :: non_neg_integer()
  def retry_limit do
    case Application.get_env(:pincer, :project_task_retry_limit, @default_retry_limit) do
      value when is_integer(value) and value >= 0 -> value
      _ -> @default_retry_limit
    end
  end

  @doc "Slugifies a binary down to `max_len` ASCII identifier characters."
  @spec slugify(String.t(), pos_integer()) :: String.t()
  def slugify(text, max_len) when is_binary(text) and is_integer(max_len) and max_len > 0 do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "project"
      value -> String.slice(value, 0, max_len)
    end
  end

  defp pending(text), do: %{status: :pending, text: text}

  defp git_adapter(opts) do
    Keyword.get(opts, :git) || Application.get_env(:pincer, :project_git, Git)
  end

  defp build_branch_name(state) do
    objective_slug =
      state.objective
      |> Wizard.fallback_text("project")
      |> slugify(36)

    session_hint =
      state.session_id
      |> Wizard.fallback_text("session")
      |> slugify(12)

    "project/#{objective_slug}-#{session_hint}"
  end

  defp current_in_progress_task(items) do
    items
    |> Enum.find(fn item -> item.status == :in_progress end)
    |> case do
      nil -> nil
      item -> item.text
    end
  end

  defp mark_first_pending_in_progress(state) do
    {items, task} = shift_first_item(state.items, :pending, :in_progress)
    {%{state | items: items}, task}
  end

  defp complete_in_progress_item(state) do
    case shift_first_item(state.items, :in_progress, :done) do
      {_items, nil} -> :noop
      {items, task} -> {:ok, %{state | items: items, retry_count: 0}, task}
    end
  end

  defp pause_in_progress_item(state) do
    {items, _task} = shift_first_item(state.items, :in_progress, :pending)
    %{state | items: items}
  end

  defp shift_first_item(items, from_status, to_status) when is_list(items) do
    Enum.reduce(items, {[], nil, false}, fn item, {acc, task, shifted?} ->
      cond do
        shifted? ->
          {[item | acc], task, true}

        item.status == from_status ->
          updated = %{item | status: to_status}
          {[updated | acc], item.text, true}

        true ->
          {[item | acc], task, false}
      end
    end)
    |> then(fn {reversed, task, _shifted} -> {Enum.reverse(reversed), task} end)
  end
end
