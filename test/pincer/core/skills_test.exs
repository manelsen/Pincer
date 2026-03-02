defmodule Pincer.Core.SkillsTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Skills

  defmodule FakeRegistry do
    def list_skills(opts), do: {:ok, Keyword.get(opts, :skills, [])}

    def fetch_skill(id, opts) do
      opts
      |> Keyword.get(:skills, [])
      |> Enum.find(fn skill ->
        (skill["id"] || skill[:id]) == id
      end)
      |> case do
        nil -> {:error, :not_found}
        skill -> {:ok, skill}
      end
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "pincer_skills_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
    end)

    {:ok, %{tmp: tmp}}
  end

  test "install/2 rejects untrusted source host", %{tmp: tmp} do
    skill = %{
      "id" => "skill-a",
      "source" => "https://evil.example.com/skill-a.tgz",
      "checksum" => "sha256:" <> String.duplicate("a", 64)
    }

    assert {:error, :untrusted_source} =
             Skills.install("skill-a",
               registry: FakeRegistry,
               registry_opts: [skills: [skill]],
               allow_install: true,
               allowed_sources: ["trusted.example.com"],
               sandbox_root: tmp
             )
  end

  test "install/2 rejects checksum mismatch", %{tmp: tmp} do
    skill = %{
      "id" => "skill-a",
      "source" => "https://trusted.example.com/skill-a.tgz",
      "checksum" => "sha256:" <> String.duplicate("a", 64)
    }

    assert {:error, {:checksum_mismatch, _, _}} =
             Skills.install("skill-a",
               registry: FakeRegistry,
               registry_opts: [skills: [skill]],
               allow_install: true,
               allowed_sources: ["trusted.example.com"],
               expected_checksum: "sha256:" <> String.duplicate("b", 64),
               sandbox_root: tmp
             )
  end

  test "install/2 enforces sandbox path and runs installer", %{tmp: tmp} do
    skill = %{
      "id" => "skill-a",
      "source" => "https://trusted.example.com/skill-a.tgz",
      "checksum" => "sha256:" <> String.duplicate("a", 64)
    }

    installer = fn _skill, dest ->
      send(self(), {:installer_called, dest})
      File.mkdir_p!(dest)
      File.write!(Path.join(dest, "ok.txt"), "ok")
      :ok
    end

    assert {:ok, %{id: "skill-a", install_path: install_path}} =
             Skills.install("skill-a",
               registry: FakeRegistry,
               registry_opts: [skills: [skill]],
               allow_install: true,
               allowed_sources: ["trusted.example.com"],
               sandbox_root: tmp,
               installer: installer
             )

    assert_received {:installer_called, ^install_path}
    assert String.starts_with?(install_path, Path.expand(tmp) <> "/")
    assert File.exists?(Path.join(install_path, "ok.txt"))
  end

  test "install/2 rejects invalid skill id", %{tmp: tmp} do
    assert {:error, :invalid_skill_id} =
             Skills.install("../evil",
               registry: FakeRegistry,
               registry_opts: [skills: []],
               allow_install: true,
               allowed_sources: ["trusted.example.com"],
               sandbox_root: tmp
             )
  end

  test "install/2 requires explicit allow_install opt-in", %{tmp: tmp} do
    skill = %{
      "id" => "skill-a",
      "source" => "https://trusted.example.com/skill-a.tgz",
      "checksum" => "sha256:" <> String.duplicate("a", 64)
    }

    assert {:error, :install_not_allowed} =
             Skills.install("skill-a",
               registry: FakeRegistry,
               registry_opts: [skills: [skill]],
               allowed_sources: ["trusted.example.com"],
               sandbox_root: tmp
             )
  end

  test "install/2 rejects non-https source even when host is allowed", %{tmp: tmp} do
    skill = %{
      "id" => "skill-a",
      "source" => "http://trusted.example.com/skill-a.tgz",
      "checksum" => "sha256:" <> String.duplicate("a", 64)
    }

    assert {:error, :untrusted_source} =
             Skills.install("skill-a",
               registry: FakeRegistry,
               registry_opts: [skills: [skill]],
               allow_install: true,
               allowed_sources: ["trusted.example.com"],
               sandbox_root: tmp
             )
  end

  test "install/2 accepts wildcard source host policy", %{tmp: tmp} do
    skill = %{
      "id" => "skill-a",
      "source" => "https://cdn.trusted.example.com/skill-a.tgz",
      "checksum" => "sha256:" <> String.duplicate("a", 64)
    }

    assert {:ok, %{id: "skill-a"}} =
             Skills.install("skill-a",
               registry: FakeRegistry,
               registry_opts: [skills: [skill]],
               allow_install: true,
               allowed_sources: ["*.trusted.example.com"],
               sandbox_root: tmp
             )
  end

  test "install/2 rejects symlink sandbox root", %{tmp: tmp} do
    real_root = Path.join(tmp, "real_root")
    link_root = Path.join(tmp, "link_root")

    File.mkdir_p!(real_root)
    :ok = File.ln_s(real_root, link_root)

    on_exit(fn ->
      File.rm_rf(link_root)
      File.rm_rf(real_root)
    end)

    skill = %{
      "id" => "skill-a",
      "source" => "https://trusted.example.com/skill-a.tgz",
      "checksum" => "sha256:" <> String.duplicate("a", 64)
    }

    assert {:error, {:unsafe_sandbox_root, _}} =
             Skills.install("skill-a",
               registry: FakeRegistry,
               registry_opts: [skills: [skill]],
               allow_install: true,
               allowed_sources: ["trusted.example.com"],
               sandbox_root: link_root
             )
  end
end
