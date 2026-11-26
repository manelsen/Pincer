defmodule Pincer.Adapters.Tools.FileSystemStructureTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.Tools.FileSystem

  @facade_file "lib/pincer/adapters/tools/file_system.ex"
  @submodule_specs [
    {"lib/pincer/adapters/tools/file_system/walk.ex", Pincer.Adapters.Tools.FileSystem.Walk},
    {"lib/pincer/adapters/tools/file_system/edit.ex", Pincer.Adapters.Tools.FileSystem.Edit},
    {"lib/pincer/adapters/tools/file_system/archive.ex",
     Pincer.Adapters.Tools.FileSystem.Archive},
    {"lib/pincer/adapters/tools/file_system/transfer.ex",
     Pincer.Adapters.Tools.FileSystem.Transfer}
  ]

  test "file_system.ex is a concise coordinator facade under 400 LOC" do
    lines = @facade_file |> File.read!() |> String.split("\n")

    assert length(lines) < 400,
           "Expected #{@facade_file} to be < 400 LOC, got #{length(lines)}"
  end

  test "file_system delegates to Walk, Edit, Archive, and Transfer submodules" do
    for {path, module} <- @submodule_specs do
      assert File.exists?(path), "Expected #{path} to exist"
      assert Code.ensure_loaded?(module), "Expected #{inspect(module)} to be loaded"
    end

    ast = @facade_file |> File.read!() |> Code.string_to_quoted!(file: @facade_file)

    assert has_alias_tail?(ast, :Walk)
    assert has_alias_tail?(ast, :Edit)
    assert has_alias_tail?(ast, :Archive)
    assert has_alias_tail?(ast, :Transfer)

    refute defines_function?(ast, :do_find_paths)
    refute defines_function?(ast, :do_search_path)
    refute defines_function?(ast, :do_list_recursive)
    refute defines_function?(ast, :apply_anchored_edits)
    refute defines_function?(ast, :validate_zip_entries)
    refute defines_function?(ast, :copy_path)
  end

  test "zero acc ++ [x] list-append loops exist in file_system.ex or file_system/*.ex" do
    files = [@facade_file | Enum.map(@submodule_specs, &elem(&1, 0))]

    for file <- files do
      assert File.exists?(file), "Expected #{file} to exist"
      source = File.read!(file)

      refute Regex.match?(~r/\+\+\s*\[/, source),
             "#{file} must not append single elements with `++ [...]`"

      ast = Code.string_to_quoted!(source, file: file)

      refute has_list_literal_append?(ast),
             "#{file} AST must not contain `++ [...]` list-append accumulations"
    end
  end

  test "single canonical action catalog drives spec/0, validation, and dispatch without triplication" do
    spec = FileSystem.spec()
    enum_actions = spec.parameters.properties.action.enum
    action_description = spec.parameters.properties.action.description

    assert FileSystem.actions() == enum_actions

    for action <- enum_actions do
      assert action_description =~ "'#{action}'",
             "Expected action description to include '#{action}'"
    end

    source = File.read!(@facade_file)
    ast = Code.string_to_quoted!(source, file: @facade_file)

    # No hardcoded action-name guard list in validate_action_path
    refute has_in_action_list?(ast, :validate_action_path)

    # Dispatch does not repeat one clause per action string literal
    perform_action_string_clauses = count_string_clauses(ast, :perform_action)
    assert perform_action_string_clauses <= 1
  end

  defp has_alias_tail?(ast, tail_atom) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:__aliases__, _, parts} = node, acc ->
          {node, acc or List.last(parts) == tail_atom}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp defines_function?(ast, fun_name) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {def_kind, _, [{^fun_name, _, _}, _]} = node, _acc when def_kind in [:def, :defp] ->
          {node, true}

        {def_kind, _, [{:when, _, [{^fun_name, _, _} | _]}, _]} = node, _acc
        when def_kind in [:def, :defp] ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp has_list_literal_append?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:++, _, [_left, rhs]} = node, _acc when is_list(rhs) ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp has_in_action_list?(ast, fun_name) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {def_kind, _, [{:when, _, [{^fun_name, _, _}, guard]}, _]} = node, acc
        when def_kind in [:def, :defp] ->
          {node, acc or contains_string_list_in?(guard)}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp contains_string_list_in?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:in, _, [_var, list]} = node, _acc when is_list(list) and length(list) > 3 ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp count_string_clauses(ast, fun_name) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn
        {def_kind, _, [{^fun_name, _, [first_arg | _]}, _]} = node, acc
        when def_kind in [:def, :defp] and is_binary(first_arg) ->
          {node, acc + 1}

        node, acc ->
          {node, acc}
      end)

    count
  end
end
