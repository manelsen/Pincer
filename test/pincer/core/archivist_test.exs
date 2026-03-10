defmodule Pincer.Core.ArchivistTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Orchestration.Archivist

  defmodule ArchivistProvider do
    use Pincer.Test.Support.LLMProviderDefaults

    @impl true
    def chat_completion([%{"content" => prompt}], _model, _config, _tools) do
      response =
        cond do
          prompt =~ "update MEMORY.md" ->
            "```markdown\n# Long-term Memory\n\n- Deployment timeout fix recorded.\n```"

          prompt =~ "extract durable user preferences" ->
            "- Prefers concise summaries.\n- Uses Telegram as the main channel."

          prompt =~ "extract \"Knowledge Snippets\"" ->
            "SNIPPET: bug_solution | 9 | Deployment timeout was fixed by increasing webhook timeout.\nSNIPPET: user_preference | 8 | User prefers concise summaries."

          prompt =~ "identify if any BUG was fixed" ->
            "BUG_FIX: Deploy timeout after webhook retries | Increase timeout to 60s | lib/pincer/deploy.ex"

          true ->
            "NONE"
        end

      {:ok, %{"role" => "assistant", "content" => response}, %{}}
    end

    @impl true
    def stream_completion(messages, model, config, tools) do
      case chat_completion(messages, model, config, tools) do
        {:ok, response, _usage} ->
          {:ok, Stream.iterate(response, fn _ -> nil end) |> Stream.take(0)}

        error ->
          error
      end
    end
  end

  defmodule StorageStub do
    @behaviour Pincer.Ports.Storage

    def indexed_documents do
      Agent.get(agent(), &Map.get(&1, :indexed_documents, []))
    end

    def bug_fixes do
      Agent.get(agent(), &Map.get(&1, :bug_fixes, []))
    end

    @impl true
    def get_messages(_session_id), do: []

    @impl true
    def save_message(_session_id, _role, _content), do: {:ok, :saved}

    @impl true
    def delete_messages(_session_id), do: :ok

    @impl true
    def ingest_bug_fix(bug_desc, fix_summary, file_path) do
      Agent.update(agent(), fn state ->
        Map.update(
          state,
          :bug_fixes,
          [%{bug: bug_desc, fix: fix_summary, file: file_path}],
          fn items ->
            items ++ [%{bug: bug_desc, fix: fix_summary, file: file_path}]
          end
        )
      end)

      :ok
    end

    @impl true
    def query_history, do: []

    @impl true
    def save_learning(_category, _summary), do: {:ok, :saved}

    @impl true
    def save_tool_error(_tool, _args, _error), do: {:ok, :saved}

    @impl true
    def list_recent_learnings(_limit), do: []

    @impl true
    def index_document(path, content, vector) do
      index_memory(path, content, "reference", vector, [])
    end

    @impl true
    def index_memory(path, content, memory_type, vector, opts) do
      Agent.update(agent(), fn state ->
        Map.update(
          state,
          :indexed_documents,
          [
            %{
              path: path,
              content: content,
              memory_type: memory_type,
              vector: vector,
              opts: Enum.into(opts, %{})
            }
          ],
          fn items ->
            items ++
              [
                %{
                  path: path,
                  content: content,
                  memory_type: memory_type,
                  vector: vector,
                  opts: Enum.into(opts, %{})
                }
              ]
          end
        )
      end)

      :ok
    end

    @impl true
    def memory_report(_limit), do: {:ok, %{}}

    @impl true
    def search_similar(_type, _vector, _limit), do: {:ok, []}

    @impl true
    def search_graph_history(_query, _limit), do: {:ok, []}

    @impl true
    def search_messages(_query, _limit), do: {:ok, []}

    @impl true
    def search_documents(_query, _limit), do: {:ok, []}

    @impl true
    def search_documents(_query, _limit, _opts), do: {:ok, []}

    @impl true
    def search_sessions(_query, _limit), do: {:ok, []}

    @impl true
    def forget_memory(_source), do: :ok

    defp agent do
      Application.fetch_env!(:pincer, :archivist_test_agent)
    end
  end

  setup do
    Application.ensure_all_started(:pincer)

    tmp = Path.join(System.tmp_dir!(), "pincer_archivist_#{System.unique_integer([:positive])}")
    workspace = Path.join(tmp, "workspaces/archivist")
    session_id = "archivist_#{System.unique_integer([:positive])}"
    agent = start_supervised!({Agent, fn -> %{} end})

    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)

    File.write!(
      AgentPaths.session_log_path(workspace, session_id),
      """
      user: The deploy timed out again.
      assistant: Increase the webhook timeout to 60s.
      user: Please keep future summaries concise.
      """
    )

    original_storage = Application.get_env(:pincer, :storage_adapter)
    original_providers = Application.get_env(:pincer, :llm_providers)
    original_default = Application.get_env(:pincer, :default_llm_provider)

    Application.put_env(:pincer, :storage_adapter, StorageStub)
    Application.put_env(:pincer, :archivist_test_agent, agent)

    Application.put_env(:pincer, :llm_providers, %{
      "archivist" => %{
        adapter: ArchivistProvider,
        env_key: "MOCK_KEY",
        default_model: "archivist-model"
      }
    })

    Application.put_env(:pincer, :default_llm_provider, "archivist")

    on_exit(fn ->
      Application.put_env(:pincer, :storage_adapter, original_storage)
      Application.put_env(:pincer, :llm_providers, original_providers)
      Application.put_env(:pincer, :default_llm_provider, original_default)
      Application.delete_env(:pincer, :archivist_test_agent)
      File.rm_rf!(tmp)
    end)

    {:ok, %{workspace: workspace, session_id: session_id}}
  end

  test "archivist updates user memory, indexes snippets and records bug fixes", %{
    workspace: workspace,
    session_id: session_id
  } do
    :ok = Archivist.consolidate(session_id, [], workspace_path: workspace)

    memory = File.read!(AgentPaths.memory_path(workspace))
    user = File.read!(AgentPaths.user_path(workspace))

    assert memory =~ "# Long-term Memory"
    refute memory =~ "```"

    assert user =~ "## Learned User Memory"
    assert user =~ "Prefers concise summaries."
    assert user =~ "Uses Telegram as the main channel."

    assert StorageStub.indexed_documents() == [
             %{
               path: "session://#{session_id}/snippet/1",
               content: "Deployment timeout was fixed by increasing webhook timeout.",
               memory_type: "bug_solution",
               vector: [],
               opts: %{importance: 9, session_id: session_id}
             },
             %{
               path: "session://#{session_id}/snippet/2",
               content: "User prefers concise summaries.",
               memory_type: "user_preference",
               vector: [],
               opts: %{importance: 8, session_id: session_id}
             }
           ]

    assert StorageStub.bug_fixes() == [
             %{
               bug: "Deploy timeout after webhook retries",
               fix: "Increase timeout to 60s",
               file: "lib/pincer/deploy.ex"
             }
           ]
  end
end
