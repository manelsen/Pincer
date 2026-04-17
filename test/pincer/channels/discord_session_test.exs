defmodule Pincer.Channels.Discord.SessionTest do
  use ExUnit.Case, async: false
  import Mox

  alias Pincer.Channels.Discord.APIMock
  alias Pincer.Channels.Discord.Session

  setup do
    Application.put_env(:pincer, :discord_api, APIMock)

    on_exit(fn ->
      Application.put_env(:pincer, :discord_api, Pincer.Channels.TestAdapter)
    end)

    verify_on_exit!()
    :ok
  end

  test "partial + final finalizes in-place without extra final send" do
    channel_id = 420
    test_pid = self()

    APIMock
    |> expect(:create_message, fn ^channel_id, "Hello ▌", _opts ->
      send(test_pid, :preview_sent)
      {:ok, %{id: 654}}
    end)
    |> expect(:edit_message, fn ^channel_id, 654, opts ->
      assert opts[:content] == "Hello world!"
      send(test_pid, :final_edited)
      {:ok, %{}}
    end)

    {:ok, pid} = Session.start_link(channel_id)
    allow(APIMock, self(), pid)

    send(pid, {:agent_partial, "Hello"})
    send(pid, {:agent_response, "Hello world!", nil})

    assert_receive :preview_sent, 1_000
    assert_receive :final_edited, 1_000
  end

  test "final-only path sends one final message without cursor" do
    channel_id = 421
    test_pid = self()

    APIMock
    |> expect(:create_message, fn ^channel_id, "Only final", _opts ->
      send(test_pid, :final_sent)
      {:ok, %{id: 700}}
    end)

    {:ok, pid} = Session.start_link(channel_id)
    allow(APIMock, self(), pid)

    send(pid, {:agent_response, "Only final", nil})

    assert_receive :final_sent, 1_000
  end

  test "worker rebinds to session scope topic and delivers response from new topic" do
    channel_id = 422
    test_pid = self()

    APIMock
    |> expect(:create_message, fn ^channel_id, "Main scope reply", _opts ->
      send(test_pid, :rebound_response_sent)
      {:ok, %{id: 701}}
    end)

    {:ok, pid} = Session.start_link(channel_id)
    allow(APIMock, self(), pid)

    assert {:error, {:already_started, ^pid}} =
             Session.ensure_started(channel_id, "discord_main")

    # Drain any pending bind casts before broadcasting.
    _ = :sys.get_state(pid)

    Pincer.Infra.PubSub.broadcast(
      "session:discord_main",
      {:agent_response, "Main scope reply", nil}
    )

    assert_receive :rebound_response_sent, 1_000
  end

  test "sub-agent status updates reuse the same discord message via edit" do
    channel_id = 423
    test_pid = self()

    APIMock
    |> expect(:create_message, fn ^channel_id, "⚙️ Sub-Agent a1 running: web.", _opts ->
      send(test_pid, :subagent_created)
      {:ok, %{id: 702}}
    end)
    |> expect(:edit_message, fn ^channel_id, 702, opts ->
      assert opts[:content] == "✅ Sub-Agent a1 finished."
      send(test_pid, :subagent_finished)
      {:ok, %{}}
    end)

    {:ok, pid} = Session.start_link(channel_id)
    allow(APIMock, self(), pid)

    send(pid, {:agent_status, "⚙️ Sub-Agent a1 running: web."})
    send(pid, {:agent_status, "✅ Sub-Agent a1 finished."})

    assert_receive :subagent_created, 1_000
    assert_receive :subagent_finished, 1_000
  end
end
