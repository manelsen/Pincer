defmodule Pincer.Core.ProjectBoard do
  @moduledoc """
  Renders a lightweight operational kanban board from `TODO.md`.

  The board is intentionally text-first so it can be delivered in CLI, Telegram,
  and Discord without channel-specific formatting logic.
  """

  @default_todo_path "TODO.md"
  @default_max_items 6

  @type board_item :: %{status: :done | :pending, text: String.t()}
  @type view :: :kanban | :project

  @doc """
  Renders a textual kanban board from a markdown checklist file.

  Options:
  - `:todo_path` - path to TODO markdown (default: `TODO.md`)
  - `:max_items` - maximum items shown per section (default: `6`)
  - `:view` - `:kanban` for concise board or `:project` for DDD/TDD guidance
  """
  @spec render(keyword()) :: String.t()
  def render(opts \\ []) do
    todo_path = Keyword.get(opts, :todo_path, @default_todo_path)
    max_items = opts |> Keyword.get(:max_items, @default_max_items) |> normalize_max_items()
    view = opts |> Keyword.get(:view, :kanban) |> normalize_view()

    case load_items(todo_path) do
      {:ok, items} ->
        build_board(items, max_items, view)

      {:error, :enoent} ->
        "Kanban unavailable: TODO.md not found in workspace."

      {:error, _reason} ->
        "Kanban unavailable: failed to read TODO.md."
    end
  end

  defp load_items(path) when is_binary(path) do
    with {:ok, content} <- File.read(path) do
      items =
        content
        |> String.split(~r/\r\n|\n|\r/)
        |> Enum.map(&parse_checklist_line/1)
        |> Enum.reject(&is_nil/1)

      {:ok, items}
    end
  end

  defp parse_checklist_line(line) when is_binary(line) do
    case Regex.run(~r/^\s*-\s*\[(x|X| )\]\s+(.+?)\s*$/, line) do
      [_, mark, text] ->
        %{
          status: if(String.downcase(mark) == "x", do: :done, else: :pending),
          text: String.trim(text)
        }

      _ ->
        nil
    end
  end

  defp parse_checklist_line(_), do: nil

  defp build_board(items, max_items, :kanban) do
    done = Enum.filter(items, &(&1.status == :done))
    pending = Enum.filter(items, &(&1.status == :pending))

    [
      "Kanban Board",
      "Done: #{length(done)} | Pending: #{length(pending)}",
      "",
      "Pending (Top #{max_items})",
      format_items(pending, max_items),
      "",
      "Done (Recent #{max_items})",
      format_items(Enum.reverse(done), max_items),
      "",
      "Flow DDD/TDD",
      "Spec -> Contract -> Red -> Green -> Refactor -> Review -> Done"
    ]
    |> Enum.join("\n")
    |> String.trim()
  end

  defp build_board(items, max_items, :project) do
    [
      build_board(items, max_items, :kanban),
      "",
      "DDD Checklist",
      "- Definir linguagem ubiqua",
      "- Delimitar bounded contexts e agregados",
      "- Confirmar contratos de interface antes da implementacao",
      "",
      "TDD Checklist",
      "- Red: escrever teste que falha",
      "- Green: implementar o minimo para o teste passar",
      "- Refactor: simplificar mantendo todos os testes verdes",
      "",
      "Next Action",
      "- Escolher um item pendente e abrir o contrato no SPECS.md"
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
        |> Enum.map(fn item -> "- #{item.text}" end)
        |> Enum.join("\n")
    end
  end

  defp normalize_max_items(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_items(_), do: @default_max_items

  defp normalize_view(:kanban), do: :kanban
  defp normalize_view(:project), do: :project
  defp normalize_view("kanban"), do: :kanban
  defp normalize_view("project"), do: :project
  defp normalize_view(_), do: :kanban
end
