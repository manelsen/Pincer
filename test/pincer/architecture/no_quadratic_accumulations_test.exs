defmodule Pincer.Architecture.NoQuadraticAccumulationsTest do
  use ExUnit.Case, async: true

  @target_functions [
    {"lib/mix/tasks/pincer.plugins.ex", :set_channel_enabled, 3},
    {"lib/pincer/core/llm/failover_policy.ex", :add_attempt, 6},
    {"lib/pincer/core/onboard.ex", :build_remote_onboard_command, 2},
    {"packages/pincer_discord/lib/pincer/channels/discord.ex", :do_send_chunks, 4},
    {"packages/pincer_discord/lib/pincer/channels/discord.ex", :build_nostrum_opts, 3},
    {"packages/pincer_shared/lib/pincer/channels/shared/chunking.ex", :split_by_lines, 2},
    {"packages/pincer_shared/lib/pincer/channels/shared/chunking.ex", :accumulate_lines, 5},
    {"packages/pincer_shared/lib/pincer/channels/shared/chunking.ex", :split_newline_window, 3},
    {"packages/pincer_shared/lib/pincer/channels/shared/chunking.ex", :do_split_newline_window, 5}
  ]

  test "target functions do not use list-append (++) accumulations" do
    Enum.each(@target_functions, fn {file, fun_name, arity} ->
      clauses = function_clauses(file, fun_name, arity)
      assert clauses != [], "Expected #{file} to define #{fun_name}/#{arity}"

      Enum.each(clauses, fn clause ->
        refute has_operator?(clause, :++),
               "#{file} #{fun_name}/#{arity} must not use ++ accumulation"
      end)
    end)
  end

  test "chunking split_newline_window avoids per-step String.slice/String.length" do
    file = "packages/pincer_shared/lib/pincer/channels/shared/chunking.ex"

    for {fun, arity} <- [{:split_newline_window, 3}, {:do_split_newline_window, 5}] do
      clauses = function_clauses(file, fun, arity)
      assert clauses != []

      Enum.each(clauses, fn clause ->
        refute has_remote_call?(clause, [:String], :slice),
               "#{file} #{fun}/#{arity} must not call String.slice"

        refute has_remote_call?(clause, [:String], :length),
               "#{file} #{fun}/#{arity} must not call String.length"
      end)
    end
  end

  defp function_clauses(file, fun_name, arity) do
    ast = file |> File.read!() |> Code.string_to_quoted!(file: file)

    {_ast, matches} =
      Macro.prewalk(ast, [], fn
        {def_kind, _, [{^fun_name, _, args}, _body]} = node, acc
        when def_kind in [:def, :defp] and is_list(args) and length(args) == arity ->
          {node, [node | acc]}

        {def_kind, _, [{:when, _, [{^fun_name, _, args} | _]}, _body]} = node, acc
        when def_kind in [:def, :defp] and is_list(args) and length(args) == arity ->
          {node, [node | acc]}

        node, acc ->
          {node, acc}
      end)

    matches
  end

  defp has_operator?(ast, op) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {^op, _, [_left, _right]} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp has_remote_call?(ast, mod_parts, fun) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, ^mod_parts}, ^fun]}, _, _args} = node, _acc ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end
end
