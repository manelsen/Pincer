defmodule Pincer.Core.Project.Wizard do
  @moduledoc """
  Pure wizard collection prompts, input parsing, and step evaluation driven by
  the authoritative `fsm_state`.
  """

  alias Pincer.Core.Project.Renderer

  @type wizard_phase :: :await_objective | :await_kind | :await_scope | :await_success | :ready
  @type project_kind :: :software | :non_software

  @type step_decision ::
          {:transition, atom(), map(), String.t()}
          | {:set_kind, project_kind(), String.t()}
          | {:finalize_plan, String.t()}
          | {:noop, map(), String.t()}

  @doc "Derives the current wizard phase from `state.fsm_state`."
  @spec phase(map() | nil) :: wizard_phase() | :unknown
  def phase(%{fsm_state: %{phase: :objective}}), do: :await_objective

  def phase(%{fsm_state: %{phase: :scope} = fsm}) do
    if is_nil(Map.get(fsm, :kind)), do: :await_kind, else: :await_scope
  end

  def phase(%{fsm_state: %{phase: :plan} = fsm}) do
    if is_nil(Map.get(fsm, :plan)), do: :await_success, else: :ready
  end

  def phase(%{fsm_state: %{phase: phase}}) when phase in [:execution, :review, :delivery],
    do: :ready

  def phase(_), do: :unknown

  @doc "Returns `true` when the project wizard is actively collecting inputs."
  @spec collecting?(map() | nil) :: boolean()
  def collecting?(state) do
    phase(state) in [:await_objective, :await_kind, :await_scope, :await_success]
  end

  @doc "Returns the prompt for the state's current derived wizard phase."
  @spec prompt(map()) :: String.t()
  def prompt(state) when is_map(state) do
    case phase(state) do
      :await_objective ->
        """
        📌 **Project Manager**
        Vamos estruturar seu projeto com fluxo multi-agente (`Architect`, `Coder`, `Reviewer`).

        Qual e o objetivo principal?
        """
        |> String.trim()

      :await_kind ->
        """
        📌 **Project Manager**
        Objetivo atual: #{state.objective}

        Qual e o tipo do projeto?
        - `software`
        - `nao-software`
        """
        |> String.trim()

      :await_scope ->
        build_scope_prompt(state.kind)

      :await_success ->
        build_success_prompt(state.kind)

      :ready ->
        Renderer.render_ready_message(state)

      :unknown ->
        "Project Manager indisponivel para esta sessao."
    end
  end

  @doc "Evaluates user input against the current wizard phase into a pure step decision."
  @spec step(map(), String.t()) :: step_decision()
  def step(state, input) when is_map(state) do
    message = normalize_text(input)

    case phase(state) do
      :await_objective ->
        objective = fallback_text(message, "Projeto sem objetivo definido")
        {:transition, :scope, %{objective: objective}, kind_prompt(objective)}

      :await_kind ->
        case parse_kind(message) do
          {:ok, kind} ->
            {:set_kind, kind, build_scope_prompt(kind)}

          :error ->
            {:noop, state, invalid_kind_prompt()}
        end

      :await_scope ->
        scope = fallback_text(message, "Sem escopo declarado")
        {:transition, :plan, %{scope: scope}, build_success_prompt(state.kind)}

      :await_success ->
        success_criteria = fallback_text(message, "Sem criterio de sucesso declarado")
        {:finalize_plan, success_criteria}

      :ready ->
        {:noop, state, Renderer.render_ready_message(state)}

      :unknown ->
        {:noop, state, "Project Manager indisponivel para esta sessao."}
    end
  end

  @doc "Parses free-form project kind responses into `:software` or `:non_software`."
  @spec parse_kind(String.t() | nil) :: {:ok, project_kind()} | :error
  def parse_kind(text) when is_binary(text) do
    normalized = text |> normalize_text() |> to_string() |> String.downcase()

    cond do
      normalized == "" ->
        :error

      Regex.match?(
        ~r/\b(nao[- ]?software|não[- ]?software|pesquisa|compra|comprar|mercado|operacao)\b/u,
        normalized
      ) ->
        {:ok, :non_software}

      Regex.match?(
        ~r/\b(software|app|aplicacao|aplicação|sistema|codigo|código|code|api|backend|frontend)\b/u,
        normalized
      ) ->
        {:ok, :software}

      true ->
        :error
    end
  end

  def parse_kind(_), do: :error

  @doc "Trims binary input or returns `nil` for non-binaries."
  @spec normalize_text(String.t() | nil) :: String.t() | nil
  def normalize_text(text) when is_binary(text), do: String.trim(text)
  def normalize_text(_), do: nil

  @doc "Returns `fallback` when `text` is `nil` or empty."
  @spec fallback_text(String.t() | nil, String.t()) :: String.t()
  def fallback_text(nil, fallback), do: fallback
  def fallback_text("", fallback), do: fallback
  def fallback_text(text, _fallback), do: text

  defp kind_prompt(objective) do
    """
    📌 **Project Manager**
    Objetivo registrado: #{objective}

    Qual e o tipo do projeto?
    - `software`
    - `nao-software`
    """
    |> String.trim()
  end

  defp invalid_kind_prompt do
    """
    Preciso classificar o projeto para montar o fluxo correto.
    Responda com `software` ou `nao-software`.
    """
    |> String.trim()
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

  defp build_scope_prompt(_kind), do: "Descreva o contexto e escopo do projeto."

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
end
