defmodule Pincer.LLM.HotSwapIntegrationTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.AgentPaths
  alias Pincer.Core.Session.Server
  alias Pincer.Infra.PubSub

  # A self-contained LLM client that does NOT read from Application.get_env(:pincer, :llm_providers).
  # This avoids race conditions with async: true tests that modify :llm_providers concurrently.
  defmodule DirectLLMClient do
    @behaviour Pincer.Ports.LLM

    @pt_key :hot_swap_integration_test_target_pid

    def register_test_pid(pid), do: :persistent_term.put(@pt_key, pid)
    def unregister_test_pid, do: :persistent_term.erase(@pt_key)

    @impl true
    def stream_completion(_messages, opts) do
      provider = Keyword.get(opts, :provider, "fail")
      do_stream(provider)
    end

    @impl true
    def chat_completion(_messages, opts) do
      provider = Keyword.get(opts, :provider, "fail")

      case do_stream(provider) do
        {:ok, [chunk | _]} ->
          content = get_in(chunk, ["choices", Access.at(0), "delta", "content"]) || ""
          {:ok, %{"content" => content}, nil}

        other ->
          other
      end
    end

    @impl true
    def list_providers, do: []

    @impl true
    def list_models(_provider_id), do: []

    @impl true
    def transcribe_audio(_path, _opts), do: {:ok, ""}

    @impl true
    def provider_config(_provider_id), do: nil

    defp do_stream("fail") do
      if pid = :persistent_term.get(@pt_key, nil), do: send(pid, :entered_backoff)
      Process.sleep(100)

      # Wait for a model swap signal or give up after a generous timeout.
      # This mirrors the receive/after block in Pincer.LLM.Client.do_request_with_retry.
      receive do
        {:model_changed, new_provider, _new_model} ->
          do_stream(new_provider)
      after
        10_000 ->
          {:error, {:http_error, 429, "Rate limited — no model swap received"}}
      end
    end

    defp do_stream("pass") do
      {:ok, [%{"choices" => [%{"delta" => %{"content" => "Swapped Successfully!"}}]}]}
    end

    defp do_stream(unknown) do
      {:error, {:unknown_provider, unknown}}
    end
  end

  defmodule MockStorage do
    def get_messages(_id), do: []
    def save_message(_id, _role, _content), do: {:ok, %{}}
    def search_similar_messages(_q, _l), do: []
    def delete_messages(_id), do: :ok
    def ingest_bug_fix(_b, _f, _fi), do: :ok
    def query_history, do: []
    def save_learning(_c, _s), do: {:ok, :ok}
    def save_tool_error(_t, _a, _e), do: {:ok, :ok}
    def list_recent_learnings(_l), do: []
    def get_document_metadata(_path, _workspace_root), do: nil
    def index_document(_p, _c, _v, _metadata), do: :ok
    def search_messages(_q, _l), do: {:ok, []}
    def search_documents(_q, _l), do: {:ok, []}
    def search_similar(_t, _v, _l), do: {:ok, []}
    def search_graph_history(_q, _l), do: {:ok, []}
  end

  setup do
    Application.ensure_all_started(:pincer)

    orig_storage = Application.get_env(:pincer, :storage_adapter)
    Application.put_env(:pincer, :storage_adapter, MockStorage)

    DirectLLMClient.register_test_pid(self())

    on_exit(fn ->
      DirectLLMClient.unregister_test_pid()
      Application.put_env(:pincer, :storage_adapter, orig_storage)
    end)

    :ok
  end

  test "session hot-swaps model during active executor backoff" do
    session_id = "test_swap_#{:rand.uniform(1000)}"
    workspace = AgentPaths.workspace_root(session_id)
    PubSub.subscribe("session:#{session_id}")

    AgentPaths.ensure_workspace!(workspace, bootstrap?: false)
    File.write!(AgentPaths.identity_path(workspace), "Integration Test Identity")
    File.write!(AgentPaths.soul_path(workspace), "Integration Test Soul")

    # 1. Start session with an injected LLM client — no global app env dependency
    {:ok, _pid} = Server.start_link(session_id: session_id, llm_client: DirectLLMClient)
    Server.set_model(session_id, "fail", "default")

    # 2. Trigger execution
    assert {:ok, :buffered} =
             Server.process_input(
               session_id,
               "Do something complex that is definitely long enough"
             )

    # 3. Wait for the signal from the DirectLLMClient that it is in "failing" state
    assert_receive :entered_backoff, 5000

    # Give it a tiny bit more time to actually enter the receive/after block
    Process.sleep(200)

    # 4. Change model while it's in backoff — this sends {:model_changed, "pass", "new-model"}
    #    to the executor task process, which is waiting inside DirectLLMClient.do_stream/1
    Server.set_model(session_id, "pass", "new-model")

    # 5. Should receive the success response
    assert_receive {:agent_response, "Swapped Successfully!", _usage}, 5000
  end
end
