defmodule Pincer.Docs.AuditDocIntegrityTest do
  use ExUnit.Case, async: true

  @doc_path "docs/AUDIT-code-quality.md"
  @repo_prefixes ~w(lib/ packages/ test/ scripts/ priv/ docs/ config/)
  @allowed_root_channel_files ~w(supervisor.ex factory.ex)

  test "audit document exists" do
    assert File.exists?(@doc_path)
  end

  test "contains no stale Postgres references" do
    content = File.read!(@doc_path)

    refute content =~ ~r/postgres\.ex/i
    refute content =~ ~r/Pincer\.Adapters\.Storage\.Postgres/
    refute content =~ ~r/postgres(?:ql)?/i
  end

  test "contains no legacy lib/pincer/channels/* adapter paths" do
    content = File.read!(@doc_path)

    refute content =~ ~r/(?<![\/\w])channels\/matrix/,
           "#{@doc_path} must not reference legacy channels/matrix paths"

    legacy_root_channels =
      Regex.scan(~r/(?<![\/\w])lib\/pincer\/channels\/([a-zA-Z0-9_.-]+)/, content)
      |> Enum.map(fn [_full, entry] -> entry end)
      |> Enum.reject(&(&1 in @allowed_root_channel_files))
      |> Enum.uniq()

    assert legacy_root_channels == [],
           "#{@doc_path} must not reference legacy root channel adapters: #{inspect(legacy_root_channels)}"
  end

  test "every repo file path referenced in backticks exists on disk" do
    content = File.read!(@doc_path)

    referenced_paths =
      Regex.scan(~r/`([^`\n]+)`/, content, capture: :all_but_first)
      |> List.flatten()
      |> Enum.filter(&repo_path_token?/1)
      |> Enum.map(&strip_line_suffix/1)
      |> Enum.uniq()

    assert referenced_paths != []

    missing =
      Enum.reject(referenced_paths, fn path ->
        File.exists?(path)
      end)

    assert missing == [],
           "Found missing repo paths in #{@doc_path}: #{inspect(missing)}"
  end

  defp repo_path_token?(token) do
    Enum.any?(@repo_prefixes, &String.starts_with?(token, &1)) and
      not String.contains?(token, " ")
  end

  defp strip_line_suffix(token) do
    Regex.replace(~r/:\d+(?:-\d+)?$/, token, "")
  end
end
