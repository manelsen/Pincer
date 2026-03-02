defmodule Pincer.Adapters.SkillsRegistry.LocalTest do
  use ExUnit.Case, async: true

  alias Pincer.Adapters.SkillsRegistry.Local

  test "list_skills/1 returns configured catalog" do
    skills = [
      %{
        "id" => "skill-a",
        "source" => "https://trusted.example.com/skill-a.tgz",
        "checksum" => "sha256:" <> String.duplicate("a", 64)
      }
    ]

    assert {:ok, ^skills} = Local.list_skills(registry: skills)
  end

  test "fetch_skill/2 returns matching skill and not_found for unknown id" do
    skills = [
      %{
        "id" => "skill-a",
        "source" => "https://trusted.example.com/skill-a.tgz",
        "checksum" => "sha256:" <> String.duplicate("a", 64)
      }
    ]

    assert {:ok, %{"id" => "skill-a"}} = Local.fetch_skill("skill-a", registry: skills)
    assert {:error, :not_found} = Local.fetch_skill("missing", registry: skills)
  end
end
