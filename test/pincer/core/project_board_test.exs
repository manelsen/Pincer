defmodule Pincer.Core.ProjectBoardTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.ProjectBoard

  describe "render/1" do
    test "builds kanban summary from TODO markdown checklist" do
      with_temp_todo_file(
        """
        # Board
        - [x] Ship onboarding
        - [ ] Add /kanban command
        - [ ] Wire /project alias
        - [x] Stabilize security suite
        """,
        fn path ->
          board = ProjectBoard.render(todo_path: path, max_items: 2)

          assert board =~ "Kanban Board"
          assert board =~ "Done: 2"
          assert board =~ "Pending: 2"
          assert board =~ "Add /kanban command"
          assert board =~ "Wire /project alias"
          assert board =~ "Spec -> Contract -> Red -> Green -> Refactor -> Review -> Done"
          refute board =~ "DDD Checklist"
          refute board =~ "TDD Checklist"
        end
      )
    end

    test "builds project guidance with explicit DDD/TDD sections" do
      with_temp_todo_file(
        """
        # Board
        - [x] Ship onboarding
        - [ ] Add /project guidance
        """,
        fn path ->
          board = ProjectBoard.render(todo_path: path, view: :project, max_items: 2)

          assert board =~ "Kanban Board"
          assert board =~ "DDD Checklist"
          assert board =~ "TDD Checklist"
          assert board =~ "Next Action"
          assert board =~ "Definir linguagem ubiqua"
          assert board =~ "Red: escrever teste que falha"
        end
      )
    end

    test "returns friendly fallback when TODO file is missing" do
      path = Path.join("trash", "missing_todo_#{System.unique_integer([:positive])}.md")

      board = ProjectBoard.render(todo_path: path)

      assert board =~ "Kanban unavailable"
      assert board =~ "TODO.md"
    end
  end

  defp with_temp_todo_file(contents, fun) do
    path = Path.join("trash", "todo_fixture_#{System.unique_integer([:positive])}.md")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end
end
