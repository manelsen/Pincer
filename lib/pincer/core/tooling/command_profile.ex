defmodule Pincer.Core.Tooling.CommandProfile do
  @moduledoc """
  Dynamic command profile derived from workspace stack artifacts.

  This module keeps a fail-closed posture: only a small explicit command set is
  enabled, and only when corresponding stack files are detected in the
  workspace root.
  """

  @type stack :: :elixir | :node | :rust | :python

  @doc """
  Detects stack markers from a workspace root.

  Supported markers:
  - Elixir: `mix.exs`
  - Node: `package.json`
  - Rust: `Cargo.toml`
  - Python: `pyproject.toml`, `requirements.txt`, `requirements-dev.txt`,
    `requirements/dev.txt`
  """
  @spec detect_stacks(keyword()) :: MapSet.t(stack())
  def detect_stacks(opts \\ []) do
    root = workspace_root(opts)

    []
    |> maybe_add_stack(marker_exists?(root, "mix.exs"), :elixir)
    |> maybe_add_stack(marker_exists?(root, "package.json"), :node)
    |> maybe_add_stack(marker_exists?(root, "Cargo.toml"), :rust)
    |> maybe_add_stack(python_marker_exists?(root), :python)
    |> MapSet.new()
  end

  @doc """
  Returns dynamic command prefixes allowed for the detected stack.
  """
  @spec dynamic_command_prefixes(keyword()) :: [[String.t()]]
  def dynamic_command_prefixes(opts \\ []) do
    root = workspace_root(opts)
    stacks = detect_stacks(opts)

    []
    |> maybe_add_prefixes(MapSet.member?(stacks, :elixir), [
      ["mix", "format"],
      ["mix", "pincer.security_audit"],
      ["mix", "pincer.doctor"]
    ])
    |> maybe_add_prefixes(MapSet.member?(stacks, :node), [
      ["npm", "test"]
    ])
    |> maybe_add_prefixes(MapSet.member?(stacks, :rust), [
      ["cargo", "test"],
      ["cargo", "check"]
    ])
    |> maybe_add_prefixes(MapSet.member?(stacks, :python), [
      ["pytest"]
    ])
    |> Kernel.++(package_script_prefixes(root))
    |> Kernel.++(make_target_prefixes(root))
    |> Kernel.++(root_shell_script_prefixes(root))
    |> Enum.uniq()
  end

  defp workspace_root(opts) do
    opts
    |> Keyword.get(:workspace_root, File.cwd!())
    |> Path.expand()
  end

  defp marker_exists?(root, relative_path) do
    root
    |> Path.join(relative_path)
    |> File.exists?()
  end

  defp python_marker_exists?(root) do
    marker_exists?(root, "pyproject.toml") or
      marker_exists?(root, "requirements.txt") or
      marker_exists?(root, "requirements-dev.txt") or
      marker_exists?(root, "requirements/dev.txt")
  end

  defp package_script_prefixes(root) do
    path = Path.join(root, "package.json")

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content),
         scripts when is_map(scripts) <- Map.get(decoded, "scripts") do
      scripts
      |> Enum.map(fn {script, _command} -> normalize_script_name(script) end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn script ->
        [
          ["npm", "run", script],
          ["yarn", "run", script],
          ["pnpm", "run", script],
          ["bun", "run", script]
        ]
      end)
    else
      _ ->
        []
    end
  end

  defp make_target_prefixes(root) do
    path = Path.join(root, "Makefile")

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split(~r/\r\n|\n|\r/, trim: true)
        |> Enum.map(&parse_make_target/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.map(fn target -> ["make", target] end)

      {:error, _reason} ->
        []
    end
  end

  defp parse_make_target(line) do
    case Regex.run(~r/^\s*([A-Za-z0-9_.-]+)\s*:(?:\s|$)/, line) do
      [_, target] ->
        if String.starts_with?(target, ".") do
          ""
        else
          target
        end

      _ ->
        ""
    end
  end

  defp root_shell_script_prefixes(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&valid_root_shell_script_name?/1)
        |> Enum.filter(fn entry ->
          root
          |> Path.join(entry)
          |> File.regular?()
        end)
        |> Enum.map(fn script_name -> ["./#{script_name}"] end)

      {:error, _reason} ->
        []
    end
  end

  defp valid_root_shell_script_name?(name) when is_binary(name) do
    not String.starts_with?(name, ".") and
      Regex.match?(~r/^[A-Za-z0-9_.-]+\.(?:sh|bash)$/, name)
  end

  defp valid_root_shell_script_name?(_), do: false

  defp normalize_script_name(script) when is_binary(script) do
    normalized = String.trim(script)

    if Regex.match?(~r/^[A-Za-z0-9._:-]+$/, normalized) do
      normalized
    else
      ""
    end
  end

  defp normalize_script_name(script) when is_atom(script),
    do: script |> Atom.to_string() |> normalize_script_name()

  defp normalize_script_name(_), do: ""

  defp maybe_add_stack(stacks, true, stack), do: [stack | stacks]
  defp maybe_add_stack(stacks, false, _stack), do: stacks

  defp maybe_add_prefixes(prefixes, true, new_prefixes), do: prefixes ++ new_prefixes
  defp maybe_add_prefixes(prefixes, false, _new_prefixes), do: prefixes
end
