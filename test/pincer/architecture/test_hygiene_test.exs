defmodule Pincer.Architecture.TestHygieneTest do
  @moduledoc """
  Enforces upper-bound ratchets on full-application boots, blind sleeps, and
  duplicated `:llm_providers` app-env mutations across `test/`.
  """
  use ExUnit.Case, async: true

  @max_app_boot_files 4
  @max_process_sleeps 20
  @max_sleep_ms 4_999
  @max_raw_llm_providers_puts 10

  test "full-application ensure_all_started(:pincer) boots stay within ratchet" do
    boot_files =
      test_source_files()
      |> Enum.filter(fn file ->
        file |> parse_ast!() |> count_app_starts() > 0
      end)

    assert length(boot_files) <= @max_app_boot_files,
           """
           Expected at most #{@max_app_boot_files} test files calling Application.ensure_all_started(:pincer),
           found #{length(boot_files)}:
           #{Enum.map_join(boot_files, "\n", &"  - #{&1}")}
           """
  end

  test "Process.sleep calls stay within ratchet and forbid >= 5_000ms or :infinity sleeps" do
    findings =
      test_source_files()
      |> Enum.flat_map(fn file ->
        file
        |> parse_ast!()
        |> find_sleeps(file)
      end)

    assert length(findings) <= @max_process_sleeps,
           """
           Expected at most #{@max_process_sleeps} Process.sleep calls across test/,
           found #{length(findings)}:
           #{Enum.map_join(findings, "\n", fn {file, line, arg} -> "  - #{file}:#{line} (#{arg})" end)}
           """

    long_sleeps =
      Enum.filter(findings, fn {_file, _line, arg} ->
        arg == :infinity or (is_integer(arg) and arg > @max_sleep_ms)
      end)

    assert long_sleeps == [],
           """
           Found forbidden Process.sleep(> #{@max_sleep_ms}ms or :infinity) calls:
           #{Enum.map_join(long_sleeps, "\n", fn {file, line, arg} -> "  - #{file}:#{line} (#{inspect(arg)})" end)}
           """
  end

  test "raw Application.put_env(:pincer, :llm_providers, ...) outside test/support and test_helper stays within ratchet" do
    offenders =
      test_source_files()
      |> Enum.reject(fn file ->
        file == "test/test_helper.exs" or String.starts_with?(file, "test/support/")
      end)
      |> Enum.flat_map(fn file ->
        file
        |> parse_ast!()
        |> find_raw_llm_provider_puts(file)
      end)

    assert length(offenders) <= @max_raw_llm_providers_puts,
           """
           Expected at most #{@max_raw_llm_providers_puts} raw Application.put_env(:pincer, :llm_providers, ...) calls outside test/support/ and test/test_helper.exs,
           found #{length(offenders)}:
           #{Enum.map_join(offenders, "\n", fn {file, line} -> "  - #{file}:#{line}" end)}
           Use Pincer.Test.Support.LLMHelpers instead.
           """
  end

  defp test_source_files do
    ["test/**/*.exs", "test/**/*.ex"]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.reject(fn file ->
      String.starts_with?(file, "test/bench/") or String.starts_with?(file, "test/fixtures/")
    end)
    |> Enum.sort()
  end

  defp parse_ast!(file) do
    file |> File.read!() |> Code.string_to_quoted!(file: file)
  end

  defp count_app_starts(ast) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn
        {{:., _, [{:__aliases__, _, [:Application]}, :ensure_all_started]}, _, [:pincer | _]} =
            node,
        acc ->
          {node, acc + 1}

        node, acc ->
          {node, acc}
      end)

    count
  end

  defp find_sleeps(ast, file) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {{:., meta, [{:__aliases__, _, [:Process]}, :sleep]}, _, [arg]} = node, acc ->
          line = Keyword.get(meta, :line, 0)
          value = if is_integer(arg) or arg == :infinity, do: arg, else: Macro.to_string(arg)
          {node, [{file, line, value} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp find_raw_llm_provider_puts(ast, file) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {{:., meta, [{:__aliases__, _, [:Application]}, :put_env]}, _,
         [:pincer, :llm_providers, _val | _]} = node,
        acc ->
          line = Keyword.get(meta, :line, 0)
          {node, [{file, line} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end
end
