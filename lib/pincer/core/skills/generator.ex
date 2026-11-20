defmodule Pincer.Core.Skills.Generator do
  @moduledoc """
  Promotes high-confidence recurring lessons from `Introspection.LessonStore`
  into validated, reusable workspace `SKILL.md` artifacts.

  Inspired by Nous Research Hermes Agent's `tools/skill_manager_tool.py`:
  - Filters mature, high-confidence unpromoted lessons
  - Synthesizes concise `agentskills.io`-compatible `SKILL.md` documents
  - Gates every generated skill fail-closed via `Pincer.Core.Skills.Guard`
  - Confines target paths inside `<workspace>/.pincer/skills/<slug>/SKILL.md`
  - Writes atomically via temp file rename and bumps patch versions on updates
  """

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Introspection.Client, as: IntrospectionClient
  alias Pincer.Core.Introspection.LessonStore
  alias Pincer.Core.Skills.Guard
  alias Pincer.Core.Skills.Manifest
  alias Pincer.Core.WorkspaceGuard

  @default_min_confidence 0.75
  @default_min_success_count 2
  @default_max_lessons 5

  @type promoted_skill :: %{
          name: String.t(),
          version: String.t(),
          description: String.t(),
          path: String.t(),
          lesson_ids: [binary()]
        }

  @doc """
  Returns eligible unpromoted active lessons for `agent_id`, sorted by confidence descending.
  """
  @spec eligible_lessons(String.t(), keyword()) :: [map()]
  def eligible_lessons(agent_id, opts \\ []) when is_binary(agent_id) do
    lesson_store = Keyword.get(opts, :lesson_store, LessonStore)
    min_conf = Keyword.get(opts, :min_confidence, @default_min_confidence)
    min_succ = Keyword.get(opts, :min_success_count, @default_min_success_count)
    max_lessons = Keyword.get(opts, :max_lessons, @default_max_lessons)

    lesson_store.list_active(agent_id)
    |> Enum.filter(fn lesson ->
      lesson.active == true and
        (lesson.confidence || 0.0) >= min_conf and
        (lesson.success_count || 0) >= min_succ and
        not promoted?(lesson)
    end)
    |> Enum.sort_by(&{&1.confidence || 0.0, &1.success_count || 0}, :desc)
    |> Enum.take(max_lessons)
  end

  @doc """
  Renders canonical `SKILL.md` content with YAML frontmatter from a skill spec map.
  """
  @spec render_skill_markdown(map(), keyword()) :: String.t()
  def render_skill_markdown(spec, opts \\ []) when is_map(spec) do
    name = Map.fetch!(spec, :name)
    version = Keyword.get(opts, :version, Map.get(spec, :version, "0.1.0"))
    description = Map.get(spec, :description, "") |> String.trim()
    when_to_use = Map.get(spec, :when_to_use, "") |> String.trim()
    steps = Map.get(spec, :steps, [])
    pitfalls = Map.get(spec, :pitfalls, [])
    lesson_ids = Map.get(spec, :lesson_ids, [])

    title =
      name
      |> String.split(~r/[-_]+/, trim: true)
      |> Enum.map_join(" ", &String.capitalize/1)

    steps_block =
      steps
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {step, idx} -> "#{idx}. #{String.trim(to_string(step))}" end)

    pitfalls_block =
      case pitfalls do
        [] ->
          ""

        items ->
          bullets = Enum.map_join(items, "\n", fn p -> "- #{String.trim(to_string(p))}" end)
          "\n## Pitfalls\n#{bullets}\n"
      end

    lessons_block =
      case lesson_ids do
        [] ->
          ""

        ids ->
          "\n## Provenance\nPromoted from verified lessons: #{Enum.join(ids, ", ")}\n"
      end

    when_block =
      if when_to_use != "" do
        "\n## When to Use\n#{when_to_use}\n"
      else
        ""
      end

    """
    ---
    name: #{Jason.encode!(name)}
    version: #{Jason.encode!(version)}
    description: #{Jason.encode!(description)}
    generated_by: "introspection_kernel"
    ---
    # #{title}
    #{when_block}
    ## Steps
    #{steps_block}
    #{pitfalls_block}#{lessons_block}
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  @doc """
  Synthesizes, security-scans, and atomically persists a workspace skill from eligible lessons.

  Returns `{:ok, :no_eligible_lessons}` when no lessons qualify,
  `{:ok, promoted_skill()}` on success, or `{:error, reason}` (fail-closed on Guard findings).
  """
  @spec promote(String.t(), keyword()) ::
          {:ok, :no_eligible_lessons | promoted_skill()} | {:error, term()}
  def promote(agent_id, opts \\ []) when is_binary(agent_id) do
    lesson_store = Keyword.get(opts, :lesson_store, LessonStore)
    workspace_path = Keyword.get(opts, :workspace_path, AgentPaths.workspace_root(agent_id))

    case eligible_lessons(agent_id, opts) do
      [] ->
        {:ok, :no_eligible_lessons}

      lessons ->
        lesson_ids = Enum.map(lessons, & &1.id)

        with {:ok, spec} <- synthesize_spec(lessons, opts),
             :ok <- Guard.validate_slug(spec.name),
             {:ok, skill_dir, target_path} <- resolve_target_paths(workspace_path, spec.name),
             version = next_version(target_path),
             markdown =
               render_skill_markdown(Map.put(spec, :lesson_ids, lesson_ids), version: version),
             {:ok, _validated} <- Guard.validate_and_scan(spec.name, markdown, opts),
             :ok <- atomic_write(skill_dir, target_path, markdown),
             :ok <- lesson_store.mark_promoted(lesson_ids, spec.name) do
          {:ok,
           %{
             name: spec.name,
             version: version,
             description: spec.description,
             path: target_path,
             lesson_ids: lesson_ids
           }}
        end
    end
  end

  # --- Private ---

  defp promoted?(lesson) do
    meta = lesson.meta || %{}
    is_binary(meta["promoted_skill"]) and meta["promoted_skill"] != ""
  end

  defp synthesize_spec(lessons, opts) do
    case Keyword.get(opts, :synthesize_mode, :llm) do
      :deterministic ->
        {:ok, deterministic_spec(lessons)}

      :llm ->
        client = Keyword.get(opts, :introspection_client, IntrospectionClient)
        messages = build_synthesis_prompt(lessons)

        case client.chat_completion(messages, []) do
          {:ok, %{"content" => content}, _usage} when is_binary(content) ->
            parse_llm_spec(content, lessons, opts)

          {:error, reason} ->
            {:error, reason}

          _other ->
            {:error, :invalid_llm_response}
        end
    end
  end

  defp build_synthesis_prompt(lessons) do
    formatted_lessons =
      Enum.map_join(lessons, "\n", fn l ->
        "- (confidence=#{l.confidence}, successes=#{l.success_count}) #{l.content}"
      end)

    system_msg = """
    You are a skill synthesis engine. Consolidate the following verified agent lessons into a concise reusable SKILL.md specification.

    Respond ONLY with a JSON object (no markdown fences):
    {
      "name": "lowercase-kebab-slug",
      "description": "Concise 1-sentence description (<= 200 chars)",
      "when_to_use": "When to apply this skill",
      "steps": ["Step 1", "Step 2"],
      "pitfalls": ["Pitfall 1"]
    }
    """

    [
      %{"role" => "system", "content" => String.trim(system_msg)},
      %{"role" => "user", "content" => "Verified Lessons:\n#{formatted_lessons}"}
    ]
  end

  defp parse_llm_spec(content, lessons, opts) do
    cleaned =
      content
      |> String.trim()
      |> String.replace(~r/\A```(?:json)?\s*/i, "")
      |> String.replace(~r/\s*```\z/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{"name" => name, "description" => desc} = parsed}
      when is_binary(name) and is_binary(desc) ->
        steps =
          case Map.get(parsed, "steps") do
            list when is_list(list) and list != [] -> Enum.map(list, &to_string/1)
            _ -> Enum.map(lessons, & &1.content)
          end

        pitfalls =
          case Map.get(parsed, "pitfalls") do
            list when is_list(list) -> Enum.map(list, &to_string/1)
            _ -> []
          end

        {:ok,
         %{
           name: String.trim(name),
           description: String.trim(desc),
           when_to_use: to_string(Map.get(parsed, "when_to_use") || ""),
           steps: steps,
           pitfalls: pitfalls
         }}

      _ ->
        if Keyword.get(opts, :fallback_deterministic, true) do
          {:ok, deterministic_spec(lessons)}
        else
          {:error, :invalid_skill_payload}
        end
    end
  end

  defp deterministic_spec([first | _] = lessons) do
    hash =
      lessons
      |> Enum.map_join("|", & &1.content)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> String.slice(0, 8)

    desc =
      first.content
      |> to_string()
      |> String.trim()
      |> String.slice(0, 180)

    %{
      name: "learned-workflow-#{hash}",
      description: desc,
      when_to_use: "Apply when handling recurring workflows matching these verified lessons.",
      steps: Enum.map(lessons, & &1.content),
      pitfalls: []
    }
  end

  defp resolve_target_paths(workspace_path, slug) do
    skills_root = AgentPaths.skills_dir(workspace_path)
    File.mkdir_p!(skills_root)

    with {:ok, skill_dir} <-
           WorkspaceGuard.confine_path(slug, root: skills_root, reject_parent_segments: true),
         {:ok, target_file} <-
           WorkspaceGuard.confine_path("SKILL.md", root: skill_dir, reject_parent_segments: true) do
      {:ok, skill_dir, target_file}
    end
  end

  defp next_version(target_path) do
    with {:ok, raw} <- File.read(target_path),
         {:ok, manifest} <- Manifest.parse(raw) do
      bump_patch_version(manifest.version)
    else
      _ -> "0.1.0"
    end
  end

  defp bump_patch_version(version) when is_binary(version) do
    case String.split(String.trim(version), ".") do
      [major, minor, patch] ->
        case Integer.parse(patch) do
          {n, ""} -> "#{major}.#{minor}.#{n + 1}"
          _ -> "0.1.1"
        end

      _ ->
        "0.1.1"
    end
  end

  defp atomic_write(skill_dir, target_path, content) do
    File.mkdir_p!(skill_dir)
    tmp_path = Path.join(skill_dir, ".SKILL.md.tmp.#{System.unique_integer([:positive])}")

    try do
      File.write!(tmp_path, content)
      File.rename!(tmp_path, target_path)
      :ok
    rescue
      e ->
        File.rm(tmp_path)
        {:error, e}
    end
  end
end
