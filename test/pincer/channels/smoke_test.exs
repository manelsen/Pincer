defmodule Pincer.Channels.SmokeTest do
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Channels.Telegram
  alias Pincer.Channels.Discord
  alias Pincer.Channels.Telegram.APIMock, as: TelegramAPIMock
  alias Pincer.Channels.Discord.APIMock, as: DiscordAPIMock

  # Simple Mock Provider for Streaming
  defmodule MockStreamProvider do
    @behaviour Pincer.LLM.Provider
    def chat_completion(_, _, _, _), do: {:ok, %{"content" => "Mock response"}}
    def stream_completion(_msgs, _model, _config, _tools) do
      stream = 
        ["Hello", " world", "!"]
        |> Stream.map(fn text -> 
          %{"choices" => [%{"delta" => %{"content" => text}}]}
        end)
      {:ok, stream}
    end
  end

  defmodule MockRegistry do
    @behaviour Pincer.Ports.ToolRegistry
    def list_tools, do: []
    def execute_tool(_, _, _), do: {:error, "Not implemented in smoke test"}
  end

  setup do
    # Ensure Pincer is running (restart to ensure clean state)
    Application.stop(:pincer)
    
    # Use Mock Registry to avoid MCP timeouts
    Application.put_env(:pincer, :core, 
      tool_registry: MockRegistry,
      llm_client: Pincer.LLM.Client
    )
    
    # Pre-stub Telegram methods that might be called during app startup
    # (The Application start might trigger Telegram Poller init)
    Mox.stub(TelegramAPIMock, :delete_webhook, fn -> {:ok, true} end)
    Mox.stub(TelegramAPIMock, :get_updates, fn _opts -> {:ok, []} end)
    
    Application.ensure_all_started(:pincer)

    # Ensure DB is ready
    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])

    # Setup Mock LLM
    original_llm = Application.get_env(:pincer, :llm_providers)
    Application.put_env(:pincer, :llm_providers, %{
      "test_provider" => %{adapter: MockStreamProvider, default_model: "test"}
    })
    Application.put_env(:pincer, :default_llm_provider, "test_provider")

    # Setup Channel Mocks
    Application.put_env(:pincer, :telegram_api, TelegramAPIMock)
    Application.put_env(:pincer, :discord_api, DiscordAPIMock)

    on_exit(fn ->
      Application.put_env(:pincer, :llm_providers, original_llm)
    end)

    verify_on_exit!()
    
    # Allow UpdatesProvider to use the mock
    if pid = Process.whereis(Pincer.Channels.Telegram.UpdatesProvider) do
      Mox.allow(TelegramAPIMock, self(), pid)
    end
    
    :ok
  end

  defp ensure_started_and_allow(module, id, mock) do
    {:ok, pid} = 
      case module.ensure_started(id) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end
    Mox.allow(mock, self(), pid)
    {:ok, pid}
  end

  test "Telegram integrated smoke test (Streaming + PubSub + API)" do
    chat_id = 12345
    session_id = "telegram_#{chat_id}"
    mid = 777

    # Intercept API calls
    # 1. First token creates the message
    TelegramAPIMock
    |> expect(:send_message, fn ^chat_id, "Hello ▌", _opts ->
         {:ok, %{message_id: mid}}
       end)
    # 2. Subsequent tokens might be debounced or final
    |> stub(:edit_message_text, fn ^chat_id, ^mid, _text, _opts ->
         {:ok, %{}}
       end)

    # Subscribe to see what's happening
    Pincer.Infra.PubSub.subscribe("session:#{session_id}")

    # Start the session workers
    ensure_started_and_allow(Telegram.Session, chat_id, TelegramAPIMock)
    
    # Assert session start
    assert {:ok, pid} = Pincer.Core.Session.Supervisor.start_session(session_id)
    assert Process.alive?(pid)

    # Trigger process
    assert {:ok, :started} = Pincer.Core.Session.Server.process_input(session_id, "Please analyze this text")

    # Assertions
    assert_receive {:agent_partial, "Hello"}, 5000
    assert_receive {:agent_partial, " world"}, 5000
    assert_receive {:agent_partial, "!"}, 5000
    assert_receive {:agent_response, "Hello world!", _usage}, 5000

    # Wait for debounced UI updates to finish
    Process.sleep(1200)
  end

  test "Discord integrated smoke test (Streaming + PubSub + API)" do
    channel_id = 999
    session_id = "discord_#{channel_id}"
    mid = 888

    # Intercept API calls
    DiscordAPIMock
    |> expect(:create_message, fn ^channel_id, "Hello ▌", _opts ->
         {:ok, %{id: mid}}
       end)
    |> stub(:edit_message, fn ^channel_id, ^mid, _opts ->
         {:ok, %{}}
       end)

    Pincer.Infra.PubSub.subscribe("session:#{session_id}")
    ensure_started_and_allow(Discord.Session, channel_id, DiscordAPIMock)
    
    assert {:ok, pid} = Pincer.Core.Session.Supervisor.start_session(session_id)
    assert Process.alive?(pid)

    assert {:ok, :started} = Pincer.Core.Session.Server.process_input(session_id, "Please analyze this text")

    assert_receive {:agent_partial, "Hello"}, 5000
    assert_receive {:agent_response, "Hello world!", _usage}, 5000

    Process.sleep(1200)
  end
end
