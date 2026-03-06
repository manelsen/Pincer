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

    Pincer.Infra.PubSub.broadcast("session:telegram_main", {:agent_response, "Main scope reply", nil})
    Process.sleep(80)
  end

  test "agent status is delivered as user-visible telegram message" do
    chat_id = 45

    APIMock
    |> expect(:send_message, fn ^chat_id, "✅ Sub-Agent a1 finished.", _opts ->
      {:ok, %{message_id: 900}}
    end)

    {:ok, pid} = Session.start_link(chat_id)
    allow(APIMock, self(), pid)

    send(pid, {:agent_status, "✅ Sub-Agent a1 finished."})

    Process.sleep(80)
  end

  test "sub-agent status updates reuse the same telegram message via edit" do
    chat_id = 46

    APIMock
    |> expect(:send_message, fn ^chat_id, "⚙️ Sub-Agent a1 running: web.", _opts ->
      {:ok, %{message_id: 910}}
    end)
    |> expect(:edit_message_text, fn ^chat_id, 910, "✅ Sub-Agent a1 finished.", opts ->
      assert opts[:parse_mode] == "HTML"
      {:ok, %{}}
    end)

    {:ok, pid} = Session.start_link(chat_id)
    allow(APIMock, self(), pid)

    send(pid, {:agent_status, "⚙️ Sub-Agent a1 running: web."})
    send(pid, {:agent_status, "✅ Sub-Agent a1 finished."})

    Process.sleep(80)
  end
end
