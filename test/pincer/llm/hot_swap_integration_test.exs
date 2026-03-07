defmodule Pincer.LLM.HotSwapIntegrationTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Session.Server
  alias Pincer.Infra.PubSub

  defmodule IntegrationMockAdapter do
    @behaviour Pincer.LLM.Provider

    @impl true
    def chat_completion(_messages, _model, config, _tools) do
      case config[:name] do
        "Failing" ->
          # Signal the test that we are about to fail and enter backoff
          if pid = config[:test_pid], do: send(pid, :entered_backoff)
          # Simulate slow failure
          Process.sleep(100)
          {:error, {:http_error, 429, "Rate limited"}}
        "Success" ->
          {:ok, %{"role" => "assistant", "content" => "Swapped Successfully!"}}
      end
    end

    @impl true
    def stream_completion(_messages, _model, config, _tools) do
      case config[:name] do
        "Failing" ->
          if pid = config[:test_pid], do: send(pid, :entered_backoff)
          Process.sleep(100)
          {:error, {:http_error, 429, "Rate limited"}}
        "Success" ->
           {:ok, [%{"choices" => [%{"delta" => %{"content" => "Swapped Successfully!"}}]}]}
      end
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
    def index_document(_p, _c, _v), do: :ok
    def search_similar(_t, _v, _l), do: {:ok, []}
  end

  setup do
    # Ensure dependencies are running
    Application.ensure_all_started(:pincer)
    
    orig_providers = Application.get_env(:pincer, :llm_providers)
    orig_storage = Application.get_env(:pincer, :storage_adapter)
    
    # SAFEGUARD: If SOUL.md exists, back it up instead of overwriting
    soul_exists = File.exists?("SOUL.md")
    if soul_exists do
      File.rename!("SOUL.md", "SOUL.md.testbackup")
    end

    # Create dummy soul for session to start in normal mode
    File.write!("SOUL.md", "Integration Test Soul")

    Application.put_env(:pincer, :storage_adapter, MockStorage)
    Application.put_env(:pincer, :llm_providers, %{
      "fail" => %{adapter: IntegrationMockAdapter, name: "Failing", env_key: "KF", test_pid: self()},
      "pass" => %{adapter: IntegrationMockAdapter, name: "Success", env_key: "KP"}
    })
    
    System.put_env("KF", "vf")
    System.put_env("KP", "vp")

    on_exit(fn ->
      Application.put_env(:pincer, :llm_providers, orig_providers)
      Application.put_env(:pincer, :storage_adapter, orig_storage)
      
      # CLEANUP: Remove test file and restore backup if it existed
      File.rm("SOUL.md")
      if soul_exists do
        File.rename!("SOUL.md.testbackup", "SOUL.md")
      end
    end)

    :ok
  end

  test "session hot-swaps model during active executor backoff" do
    session_id = "test_swap_#{:rand.uniform(1000)}"
    PubSub.subscribe("session:#{session_id}")

    # 1. Start session with failing model
    {:ok, _pid} = Server.start_link(session_id: session_id)
    Server.set_model(session_id, "fail", "default")

    # 2. Trigger execution
    assert {:ok, :buffered} =
             Server.process_input(session_id, "Do something complex that is definitely long enough")

    # 3. Wait for the signal from adapter that it failed and is about to retry (waiting)
    assert_receive :entered_backoff, 5000
    
    # Give it a tiny bit more time to actually enter the receive/after block in Client
    Process.sleep(200)

    # 4. Change model while it's in backoff
    Server.set_model(session_id, "pass", "new-model")

    # 5. Should receive the success response soon (much faster than 429 retries)
    assert_receive {:agent_response, "Swapped Successfully!", _usage}, 5000
  end
end
