defmodule Pincer.Channels.WebhookListenerTest do
  use ExUnit.Case, async: false

  alias Pincer.Channels.Webhook
  alias Pincer.Channels.Webhook.Listener

  @token_env "PINCER_WEBHOOK_LISTENER_TEST_TOKEN"
  @token "listener-top-secret"
  @path "/webhook/message"

  setup do
    parent = self()
    System.put_env(@token_env, @token)

    on_exit(fn -> System.delete_env(@token_env) end)

    channel_config = %{
      "session_mode" => "per_sender",
      "default_source" => "external",
      "default_session_id" => "webhook_main",
      "max_dedup" => 64,
      "token_env" => @token_env,
      "ensure_session_started_fn" => fn session_id ->
        send(parent, {:ensure_session, session_id})
        :ok
      end,
      "process_input_fn" => fn session_id, text ->
        send(parent, {:process_input, session_id, text})
        {:ok, :started}
      end
    }

    {:ok, parent: parent, channel_config: channel_config}
  end

  test "accepts a signed POST end to end and processes the message exactly once", %{
    channel_config: channel_config
  } do
    start_channel!(channel_config)
    port = free_port()

    start_listener!(%{
      "token_env" => @token_env,
      "port" => port,
      "bind" => "127.0.0.1",
      "path" => @path
    })

    payload = %{
      "event_id" => "evt-http-1",
      "source" => "github",
      "sender_id" => "42",
      "text" => "Build finished via HTTP."
    }

    response =
      Req.post!(url(port), json: payload, headers: [{"x-pincer-token", @token}])

    assert response.status == 202
    assert %{"status" => "accepted", "session_id" => "webhook_github_42"} = response.body

    assert_receive {:ensure_session, "webhook_github_42"}
    assert_receive {:process_input, "webhook_github_42", "Build finished via HTTP."}
    refute_receive {:process_input, _, _}, 50
  end

  test "rejects a POST without a token and never processes it", %{channel_config: channel_config} do
    start_channel!(channel_config)
    port = free_port()

    start_listener!(%{
      "token_env" => @token_env,
      "port" => port,
      "bind" => "127.0.0.1",
      "path" => @path
    })

    response =
      Req.post!(url(port), json: %{"event_id" => "evt-http-2", "text" => "unauthorized"})

    assert response.status == 401
    refute_receive {:ensure_session, _}, 50
    refute_receive {:process_input, _, _}, 50
  end

  test "returns :ignore when the token environment variable is not configured" do
    missing_env = "PINCER_WEBHOOK_LISTENER_MISSING_TOKEN"
    System.delete_env(missing_env)

    config = %{
      "token_env" => missing_env,
      "port" => free_port(),
      "bind" => "127.0.0.1",
      "path" => @path
    }

    assert Listener.start_link(config) == :ignore
  end

  defp url(port), do: "http://127.0.0.1:#{port}#{@path}"

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp start_channel!(config) do
    {:ok, pid} = Webhook.start_link(config)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    pid
  end

  defp start_listener!(config) do
    {:ok, pid} = Listener.start_link(config)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          Supervisor.stop(pid)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    pid
  end
end
