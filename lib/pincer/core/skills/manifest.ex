defmodule Pincer.Core.Skills.Manifest do
  @moduledoc """
  Parse skill manifests from markdown files with YAML frontmatter.

  A skill file is a markdown document with a YAML header delimited by `---`.
  The frontmatter contains metadata (name, version, description, requirements,
  provides). The body contains agent-facing instructions.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          description: String.t(),
          requirements: [map()],
          provides: [map()],
          body: String.t(),
          source_path: String.t() | nil
        }

  defstruct [:name, :version, :description, :requirements, :provides, :body, :source_path]

  @doc "Parse a skill manifest from markdown content with YAML frontmatter."
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(content) do
    with {:ok, frontmatter, body} <- split_frontmatter(content),
         {:ok, parsed} <- YamlElixir.read_from_string(frontmatter),
         :ok <- validate_name(parsed) do
      manifest = %__MODULE__{
        name: parsed["name"],
        version: parsed["version"] || "0.1.0",
        description: parsed["description"] || "",
        requirements: parsed["requirements"] || [],
        provides: parsed["provides"] || [],
        body: String.trim(body),
        source_path: nil
      }

      {:ok, manifest}
    end
  end

  defp split_frontmatter(content) do
    case String.split(content, "---", parts: 3) do
      ["", frontmatter, body] ->
        {:ok, frontmatter, body}

      _ ->
        {:error, :invalid_frontmatter}
    end
  end

  defp validate_name(%{"name" => name}) when is_binary(name) and name != "", do: :ok
  defp validate_name(_), do: {:error, :missing_name}
end
