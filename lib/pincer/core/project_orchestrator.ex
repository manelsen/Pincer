defmodule Pincer.Core.ProjectOrchestrator do
  @moduledoc """
  Session-scoped project orchestration flow used by `/project` and `/kanban`.

  This module provides a lightweight project manager wizard with explicit
  multi-agent framing (Architect, Coder, Reviewer). It supports software and
  non-software projects and keeps per-session state in ETS.
  """

  @table __MODULE__
  @default_max_items 6

  @type phase :: :await_objective | :await_kind | :await_scope | :await_success | :ready
  @type project_kind :: :software | :non_software

  @type state :: %{
          session_id: String.t(),
          phase: phase(),
          objective: String.t() | nil,
          kind: project_kind() | nil,
          scope: String.t() | nil,
          success_criteria: String.t() | nil,
          items: [map()],
          git_branch: String.t() | nil,
          git_branch_status: :created | :existing | {:error, any()} | nil
        }

  @doc """
  Starts (or resumes) the project wizard for a session.

  Optional `seed_input` can be used to immediately answer the current step.
  """
  @spec start(String.t(), String.t() | nil) :: String.t()
  def start(session_id, seed_input \\ nil) when is_binary(session_id) do
    ensure_table()

    case normalize_text(seed_input) do
      "reset" ->
        reset(session_id)
        prompt_for_phase(new_state(session_id))

      seed ->
        state = get_or_create_state(session_id)

        if seed in [nil, ""] do
          prompt_for_phase(state)
        else
          advance(session_id, state, seed)
        end
    end
  end

  @doc """
  Continues wizard collection from free-form user messages.

  Returns `:not_active` when the session is not in an active wizard phase.
  """
  @spec continue(String.t(), String.t()) :: {:handled, String.t()} | :not_active
  def continue(session_id, user_message) when is_binary(session_id) and is_binary(user_message) do
    ensure_table()

    case get_state(session_id) do
      %{phase: phase} = state
      when phase in [:await_objective, :await_kind, :await_scope, :await_success] ->
        {:handled, advance(session_id, state, user_message)}

      _ ->
        :not_active
    end
  end

  @doc """
  Returns `true` when the project wizard is currently collecting information.
  """
  @spec collecting?(String.t()) :: boolean()
  def collecting?(session_id) when is_binary(session_id) do
    ensure_table()

    case get_state(session_id) do
      %{phase: phase}
      when phase in [:await_objective, :await_kind, :await_scope, :await_success] ->
        true

      _ ->
        false
    end
  end

  @doc """
  Renders a kanban board from the session project state when available.
  """
  @spec board(String.t(), keyword()) :: {:ok, String.t()} | :not_found
  def board(session_id, opts \\ []) when is_binary(session_id) do
    ensure_table()
    max_items = opts |> Keyword.get(:max_items, @default_max_items) |> normalize_max_items()

    case get_state(session_id) do
      %{phase: :ready} = state ->
        {:ok, render_board(state, max_items)}

      _ ->
        :not_found
    end
  end

  @doc """
  Clears project orchestration state for a single session.
  """
  @spec reset(String.t()) :: :ok
  def reset(session_id) when is_binary(session_id) do
    ensure_table()
    :ets.delete(@table, session_id)
    :ok
  end

  @doc false
  @spec reset_all() :: :ok
  def reset_all do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp get_or_create_state(session_id) do
    case get_state(session_id) do
      nil ->
        state = new_state(session_id)
        put_state(state)
        state

      state ->
        state
    end
  end

  defp new_state(session_id) do
    %{
      session_id: session_id,
      phase: :await_objective,
      objective: nil,
      kind: nil,
      scope: nil,
      success_criteria: nil,
      items: [],
      git_branch: nil,
      git_branch_status: nil
    }
  end

  defp advance(_session_id, state, input) do
    message = normalize_text(input)

    case state.phase do
      :await_objective ->
        objective = fallback_text(message, "Projeto sem objetivo definido")
        next_state = %{state | phase: :await_kind, objective: objective}
        put_state(next_state)

        """
        📌 **Project Manager**
        Objetivo registrado: #{objective}

        Qual e o tipo do projeto?
        - `software`
        - `nao-software`
        """
        |> String.trim()

      :await_kind ->
        case parse_kind(message) do
          {:ok, kind} ->
            next_state = %{state | phase: :await_scope, kind: kind}
            put_state(next_state)
            build_scope_prompt(kind)

          :error ->
            """
            Preciso classificar o projeto para montar o fluxo correto.
            Responda com `software` ou `nao-software`.
            """
            |> String.trim()
        end

      :await_scope ->
        scope = fallback_text(message, "Sem escopo declarado")
        next_state = %{state | phase: :await_success, scope: scope}
        put_state(next_state)
        build_success_prompt(state.kind)

      :await_success ->
        success_criteria = fallback_text(message, "Sem criterio de sucesso declarado")
        ready_state = finalize_state(%{state | success_criteria: success_criteria, phase: :ready})
        put_state(ready_state)
        render_ready_message(ready_state)

      :ready ->
        render_ready_message(state)
    end
  end

  defp finalize_state(state) do
    state
    |> Map.put(:items, build_items(state))
    |> ensure_project_branch()
  end

  defp build_items(%{kind: :software, objective: objective, scope: scope}) do
    [
      pending("Architect: definir linguagem ubiqua e limites de dominio para '#{objective}'"),
      pending("Architect: consolidar contrato inicial no SPECS.md com escopo '#{scope}'"),
      pending("Coder: Red - escrever teste que falha para o primeiro incremento"),
      pending("Coder: Green - implementar o minimo para o teste passar"),
      pending("Coder: Refactor - simplificar mantendo testes verdes"),
      pending("Reviewer: validar cobertura (caminho feliz + erro) e criterio de aceite")
    ]
  end

  defp build_items(%{kind: :non_software, objective: objective, scope: scope}) do
    [
      pending("Architect: definir criterio objetivo para '#{objective}'"),
      pending("Coder: pesquisar opcoes reais dentro do escopo '#{scope}'"),
      pending("Coder: comparar custo-beneficio, disponibilidade e riscos"),
      pending("Reviewer: validar fonte e data de cada evidencia"),
      pending("Reviewer: propor recomendacao final com trade-offs")
    ]
  end

  defp build_items(_state), do: []

  defp pending(text), do: %{status: :pending, text: text}

  defp render_ready_message(state) do
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

  defp render_board(state, max_items) do
    done = Enum.filter(state.items, &(&1.status == :done))
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
      "Done: #{length(done)} | Pending: #{length(pending)}",
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

  defp format_items(items, max_items) do
    items
    |> Enum.take(max_items)
    |> case do
      [] ->
        "- (none)"

      selected ->
        selected
        |> Enum.map_join("\n", fn item -> "- #{item.text}" end)
    end
  end

  defp build_scope_prompt(:software) do
    """
    Descreva o contexto e escopo funcional.
    Exemplo: canais afetados, modulo alvo, restricoes de arquitetura.
    """
    |> String.trim()
  end

  defp build_scope_prompt(:non_software) do
    """
    Descreva o contexto e escopo da pesquisa.
    Exemplo: cidade, faixa de preco, marcas preferidas, restricoes.
    """
    |> String.trim()
  end

  defp build_scope_prompt(_kind) do
    "Descreva o contexto e escopo do projeto."
  end

  defp build_success_prompt(:software) do
    """
    Qual e o criterio de sucesso?
    Exemplo: testes passando, endpoint entregue, comportamento validado em canal.
    """
    |> String.trim()
  end

  defp build_success_prompt(:non_software) do
    """
    Qual e o criterio de sucesso?
    Exemplo: ranking final com evidencias e recomendacao de compra objetiva.
    """
    |> String.trim()
  end

  defp build_success_prompt(_kind), do: "Qual e o criterio de sucesso deste projeto?"

  defp prompt_for_phase(%{phase: :await_objective}) do
    """
    📌 **Project Manager**
    Vamos estruturar seu projeto com fluxo multi-agente (`Architect`, `Coder`, `Reviewer`).

    Qual e o objetivo principal?
    """
    |> String.trim()
  end

  defp prompt_for_phase(%{phase: :await_kind, objective: objective}) do
    """
    📌 **Project Manager**
    Objetivo atual: #{objective}

    Qual e o tipo do projeto?
    - `software`
    - `nao-software`
    """
    |> String.trim()
  end

  defp prompt_for_phase(%{phase: :await_scope, kind: kind}) do
    build_scope_prompt(kind)
  end

  defp prompt_for_phase(%{phase: :await_success, kind: kind}) do
    build_success_prompt(kind)
  end

  defp prompt_for_phase(%{phase: :ready} = state) do
    render_ready_message(state)
  end

  defp prompt_for_phase(_state) do
    "Project Manager indisponivel para esta sessao."
  end

  defp parse_kind(text) when is_binary(text) do
    normalized = normalize_text(text) |> to_string() |> String.downcase()

    cond do
      normalized == "" ->
        :error

      Regex.match?(
        ~r/\b(nao[- ]?software|pesquisa|compra|comprar|mercado|operacao)\b/,
        normalized
      ) ->
        {:ok, :non_software}

      Regex.match?(
        ~r/\b(software|app|aplicacao|sistema|codigo|code|api|backend|frontend)\b/,
        normalized
      ) ->
        {:ok, :software}

      true ->
        :error
    end
  end

  defp parse_kind(_), do: :error

  defp kind_label(:software), do: "software"
  defp kind_label(:non_software), do: "nao-software"
  defp kind_label(_), do: "indefinido"

  defp normalize_text(text) when is_binary(text) do
    text
    |> String.trim()
  end

  defp normalize_text(_), do: nil

  defp fallback_text(nil, fallback), do: fallback
  defp fallback_text("", fallback), do: fallback
  defp fallback_text(text, _fallback), do: text

  defp ensure_project_branch(%{git_branch: branch} = state)
       when is_binary(branch) and branch != "" do
    state
  end

  defp ensure_project_branch(state) do
    branch_name = build_branch_name(state)

    case git_adapter().ensure_branch(branch_name) do
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

  defp git_summary(%{git_branch: branch, git_branch_status: status})
       when is_binary(branch) and status in [:created, :existing] do
    status_label =
      case status do
        :created -> "criada"
        :existing -> "ja existente"
      end

    """
    **Git Branch**
    - `#{branch}` (#{status_label}, sem checkout automatico)
    - Proximo passo: `git checkout #{branch}`
    """
    |> String.trim()
  end

  defp git_summary(%{git_branch: branch, git_branch_status: {:error, reason}})
       when is_binary(branch) do
    """
    **Git Branch**
    - Falha ao preparar branch automaticamente: #{format_branch_error(reason)}
    - Sugestao manual: `git checkout -b #{branch}`
    """
    |> String.trim()
  end

  defp git_summary(_state) do
    """
    **Git Branch**
    - Branch nao preparada automaticamente.
    """
    |> String.trim()
  end

  defp build_branch_name(state) do
    objective_slug =
      state.objective
      |> fallback_text("project")
      |> slugify(36)

    session_hint =
      state.session_id
      |> fallback_text("session")
      |> slugify(12)

    "project/#{objective_slug}-#{session_hint}"
  end

  defp slugify(text, max_len) when is_binary(text) and is_integer(max_len) and max_len > 0 do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "project"
      value -> String.slice(value, 0, max_len)
    end
  end

  defp format_branch_error(reason) do
    case reason do
      {:branch_create_failed, detail} -> detail
      {:git_unavailable, detail} -> detail
      other -> inspect(other)
    end
  end

  defp git_adapter do
    Application.get_env(:pincer, :project_git, Pincer.Core.ProjectGit)
  end

  defp get_state(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, state}] -> state
      _ -> nil
    end
  end

  defp put_state(%{session_id: session_id} = state) do
    :ets.insert(@table, {session_id, state})
    state
  end

  defp normalize_max_items(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_items(_), do: @default_max_items

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError ->
      # Race-safe: another process created the table between whereis and new.
      :ok
  end
end
