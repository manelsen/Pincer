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

    APIMock
    |> expect(:create_message, fn ^channel_id, "Hello ▌", _opts ->
      {:ok, %{id: 654}}
    end)
    |> expect(:edit_message, fn ^channel_id, 654, opts ->
      assert opts[:content] == "Hello world!"
      {:ok, %{}}
    end)

    {:ok, pid} = Session.start_link(channel_id)
    allow(APIMock, self(), pid)

    send(pid, {:agent_partial, "Hello"})
    send(pid, {:agent_response, "Hello world!"})

    Process.sleep(80)
  end

  test "final-only path sends one final message without cursor" do
    channel_id = 421

    APIMock
    |> expect(:create_message, fn ^channel_id, "Only final", _opts ->
      {:ok, %{id: 700}}
    end)

    {:ok, pid} = Session.start_link(channel_id)
    allow(APIMock, self(), pid)

    send(pid, {:agent_response, "Only final"})

    Process.sleep(80)
  end

  test "worker rebinds to session scope topic and delivers response from new topic" do
    channel_id = 422

    APIMock
    |> expect(:create_message, fn ^channel_id, "Main scope reply", _opts ->
      {:ok, %{id: 701}}
    end)

    {:ok, pid} = Session.start_link(channel_id)
    allow(APIMock, self(), pid)

    assert {:error, {:already_started, ^pid}} =
             Session.ensure_started(channel_id, "discord_main")

    Process.sleep(50)

    Pincer.PubSub.broadcast("session:discord_main", {:agent_response, "Main scope reply"})
    Process.sleep(80)
  end

  test "sub-agent status updates reuse the same discord message via edit" do
    channel_id = 423

    APIMock
    |> expect(:create_message, fn ^channel_id, "⚙️ Sub-Agent a1 running: web.", _opts ->
      {:ok, %{id: 702}}
    end)
    |> expect(:edit_message, fn ^channel_id, 702, opts ->
      assert opts[:content] == "✅ Sub-Agent a1 finished."
      {:ok, %{}}
    end)

    {:ok, pid} = Session.start_link(channel_id)
    allow(APIMock, self(), pid)

    send(pid, {:agent_status, "⚙️ Sub-Agent a1 running: web."})
    send(pid, {:agent_status, "✅ Sub-Agent a1 finished."})

    Process.sleep(80)
  end
end
