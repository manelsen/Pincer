defmodule Pincer.Channels.Telegram.SessionTest do
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Channels.Telegram.APIMock
  alias Pincer.Channels.Telegram.Session

  setup do
    Application.put_env(:pincer, :telegram_api, APIMock)

    on_exit(fn ->
      Application.put_env(:pincer, :telegram_api, Pincer.Channels.TestAdapter)
    end)

    verify_on_exit!()
    :ok
  end

  test "partial + final finalizes in-place without extra final send" do
    chat_id = 42

    APIMock
    |> expect(:send_message, fn ^chat_id, "Hello ▌", _opts ->
      {:ok, %{message_id: 321}}
    end)
    |> expect(:edit_message_text, fn ^chat_id, 321, "Hello world!", opts ->
      assert opts[:parse_mode] == "HTML"
      {:ok, %{}}
    end)

    {:ok, pid} = Session.start_link(chat_id)
    allow(APIMock, self(), pid)

    send(pid, {:agent_partial, "Hello"})
    send(pid, {:agent_response, "Hello world!", nil})

    Process.sleep(80)
  end

  test "final-only path sends one final message without cursor" do
    chat_id = 43

    APIMock
    |> expect(:send_message, fn ^chat_id, "Only final", _opts ->
      {:ok, %{message_id: 500}}
    end)

    {:ok, pid} = Session.start_link(chat_id)
    allow(APIMock, self(), pid)

    send(pid, {:agent_response, "Only final", nil})

    Process.sleep(80)
  end

  test "large single-token partial waits for final and avoids preview duplication" do
    chat_id = 47
    test_pid = self()
    large_body = String.duplicate("a", 4201)
    payload = "<thinking>internal</thinking>\n\n" <> large_body

    APIMock
    |> expect(:send_message, fn ^chat_id, text, opts ->
      assert text == large_body
      assert opts[:parse_mode] == "HTML"
      {:error, %Telegex.Error{error_code: 400, description: "Bad Request: message is too long"}}
    end)
    |> expect(:send_message, fn ^chat_id, text, opts ->
      assert text == String.duplicate("a", 4000)
      assert opts[:parse_mode] == "HTML"
      send(test_pid, {:telegram_chunk, 1, text})
      {:ok, %{message_id: 1001}}
    end)
    |> expect(:send_message, fn ^chat_id, text, opts ->
      assert text == String.duplicate("a", 201)
      assert opts[:parse_mode] == "HTML"
      send(test_pid, {:telegram_chunk, 2, text})
      {:ok, %{message_id: 1002}}
    end)

    {:ok, pid} = Session.start_link(chat_id)
    allow(APIMock, self(), pid)

    send(pid, {:agent_partial, payload})
    Process.sleep(80)
    refute_receive {:telegram_chunk, _, _}, 50

    send(pid, {:agent_response, payload, nil})

    assert_receive {:telegram_chunk, 1, _}, 500
    assert_receive {:telegram_chunk, 2, _}, 500
    refute_receive {:telegram_chunk, _, _}, 100
  end

  test "worker rebinds to session scope topic and delivers response from new topic" do
    chat_id = 44

    APIMock
    |> expect(:send_message, fn ^chat_id, "Main scope reply", _opts ->
      {:ok, %{message_id: 700}}
    end)

    {:ok, pid} = Session.start_link(chat_id)
    allow(APIMock, self(), pid)

    assert {:error, {:already_started, ^pid}} =
             Session.ensure_started(chat_id, "telegram_main")

    Process.sleep(50)

    Pincer.Infra.PubSub.broadcast(
      "session:telegram_main",
      {:agent_response, "Main scope reply", nil}
    )

    Process.sleep(80)
  end

  test "non sub-agent status is delivered as user-visible telegram message" do
    chat_id = 45

    APIMock
    |> expect(:send_message, fn ^chat_id, "Status update", _opts ->
      {:ok, %{message_id: 900}}
    end)

    {:ok, pid} = Session.start_link(chat_id)
    allow(APIMock, self(), pid)

    send(pid, {:agent_status, "Status update"})

    Process.sleep(80)
  end

  test "sub-agent progress creates and updates a single telegram checklist message" do
    chat_id = 46

    APIMock
    |> expect(:send_message, fn ^chat_id, text, _opts ->
      assert text =~ "Sub-Agent Checklist"
      assert text =~ "<code>a1</code>"
      assert text =~ "Goal: review repo"
      assert text =~ "☑ Started"
      assert text =~ "☐ Finished"
      {:ok, %{message_id: 910}}
    end)
    |> expect(:edit_message_text, fn ^chat_id, 910, text, opts ->
      assert text =~ "Last tool: <code>web.search</code>"
      assert text =~ "☐ Finished"
      assert opts[:parse_mode] == "HTML"
      {:ok, %{}}
    end)
    |> expect(:edit_message_text, fn ^chat_id, 910, text, opts ->
      assert text =~ "☑ Finished"
      assert text =~ "Result: done"
      assert opts[:parse_mode] == "HTML"
      {:ok, %{}}
    end)

    {:ok, pid} = Session.start_link(chat_id)
    allow(APIMock, self(), pid)

    send(pid, {:subagent_progress, %{agent_id: "a1", kind: :started, goal: "review repo"}})
    send(pid, {:subagent_progress, %{agent_id: "a1", kind: :tool, tool: "web.search"}})
    send(pid, {:subagent_progress, %{agent_id: "a1", kind: :finished, result: "done"}})

    Process.sleep(80)
  end

  test "sub-agent textual status is ignored when structured progress is available" do
    chat_id = 47

    {:ok, pid} = Session.start_link(chat_id)
    allow(APIMock, self(), pid)

    send(pid, {:agent_status, "✅ Sub-Agent a1 finished."})

    Process.sleep(80)
  end
end
