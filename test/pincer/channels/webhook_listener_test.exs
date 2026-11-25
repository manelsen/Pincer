defmodule Pincer.Channels.WebhookListenerTest do
  use ExUnit.Case, async: false

  alias Pincer.Channels.{Factory, Webhook}
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

  test "accepts a signed POST exactly once through the listener started by the factory", %{
    channel_config: channel_config
  } do
    port = free_port()

    start_webhook_from_factory!(
      Map.merge(channel_config, %{
        "port" => port,
        "path" => "/custom-webhook"
      })
    )

    payload = %{
      "event_id" => "evt-http-1",
      "source" => "github",
      "sender_id" => "42",
      "text" => "Build finished via HTTP."
    }

    response =
      Req.post!("http://127.0.0.1:#{port}/custom-webhook",
        json: payload,
        headers: [{"x-pincer-token", @token}]
      )

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

  test "the factory starts neither the channel nor the listener when the token is missing" do
    missing_env = "PINCER_WEBHOOK_LISTENER_MISSING_TOKEN"
    System.delete_env(missing_env)

    supervisor = start_webhook_from_factory!(%{"token_env" => missing_env, "port" => 0})

    assert %{specs: 2, active: 0} = Supervisor.count_children(supervisor)
  end

  test "starts the rate limiter before Bandit and limits signed requests", %{
    channel_config: channel_config
  } do
    start_channel!(channel_config)
    port = free_port()

    listener =
      start_listener!(%{
        "token_env" => @token_env,
        "port" => port,
        "bind" => "127.0.0.1",
        "path" => @path,
        "rate_limit_per_minute" => 2
      })

    children = Supervisor.which_children(listener)

    assert Enum.any?(children, fn {id, _pid, _type, _modules} ->
             id == Pincer.Channels.Webhook.RateLimiter
           end)

    assert Enum.any?(children, fn {id, _pid, _type, _modules} -> match?({Bandit, _}, id) end)
    assert is_pid(Process.whereis(Pincer.Channels.Webhook.RateLimiter))

    responses =
      for index <- 1..3 do
        Req.post!(url(port),
          json: %{"text" => "message #{index}"},
          headers: [{"x-pincer-token", @token}]
        )
      end

    assert Enum.map(Enum.take(responses, 2), & &1.status) == [202, 202]

    rejected = Enum.at(responses, 2)
    assert rejected.status == 429
    assert %{"error" => "rate_limited"} = rejected.body

    assert [retry_after] = Req.Response.get_header(rejected, "retry-after")
    assert {seconds, ""} = Integer.parse(retry_after)
    assert seconds >= 1
  end

  test "does not start a limiter when rate_limit_per_minute is 0", %{
    channel_config: channel_config
  } do
    start_channel!(channel_config)
    port = free_port()

    start_listener!(%{
      "token_env" => @token_env,
      "port" => port,
      "bind" => "127.0.0.1",
      "path" => @path,
      "rate_limit_per_minute" => 0
    })

    assert Process.whereis(Pincer.Channels.Webhook.RateLimiter) == nil

    for index <- 1..3 do
      response =
        Req.post!(url(port),
          json: %{"text" => "unlimited #{index}"},
          headers: [{"x-pincer-token", @token}]
        )

      assert response.status == 202
    end
  end

  test "falls back to the default limit and logs once for invalid rate_limit_per_minute", %{
    channel_config: channel_config
  } do
    import ExUnit.CaptureLog

    start_channel!(channel_config)
    port = free_port()

    log =
      capture_log(fn ->
        start_listener!(%{
          "token_env" => @token_env,
          "port" => port,
          "bind" => "127.0.0.1",
          "path" => @path,
          "rate_limit_per_minute" => "not-a-number"
        })
      end)

    assert log =~ "rate_limit_per_minute"
    assert length(String.split(log, "rate_limit_per_minute")) == 2
    assert is_pid(Process.whereis(Pincer.Channels.Webhook.RateLimiter))

    response =
      Req.post!(url(port),
        json: %{"text" => "still accepted"},
        headers: [{"x-pincer-token", @token}]
      )

    assert response.status == 202
  end

  defp url(port), do: "http://127.0.0.1:#{port}#{@path}"

  defp start_webhook_from_factory!(config) do
    config =
      Map.merge(config, %{
        "adapter" => "Pincer.Channels.Webhook",
        "enabled" => true,
        "bind" => "127.0.0.1"
      })

    specs = Factory.create_channel_specs(%{"webhook" => config}, [])

    start_supervised!(%{
      id: :webhook_channel_supervisor,
      start: {Supervisor, :start_link, [specs, [strategy: :one_for_one]]}
    })
  end

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
