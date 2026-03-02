defmodule Pincer.Channels.WebhookTest do
  use ExUnit.Case, async: false

  alias Pincer.Channels.Webhook

  setup do
    parent = self()
    token_env = "PINCER_WEBHOOK_TEST_TOKEN"
    token = "top-secret"
    System.put_env(token_env, token)

    on_exit(fn ->
      System.delete_env(token_env)
    end)

    base_config = %{
      "session_mode" => "per_sender",
      "default_source" => "external",
      "default_session_id" => "webhook_main",
      "max_dedup" => 64,
      "token_env" => token_env,
      "ensure_session_started_fn" => fn session_id ->
        send(parent, {:ensure_session, session_id})
        :ok
      end,
      "process_input_fn" => fn session_id, text ->
        send(parent, {:process_input, session_id, text})
        {:ok, :started}
      end
    }

    {:ok, base_config: base_config, token: token}
  end

  test "accepts webhook payload and routes message to derived session", %{
    base_config: config,
    token: token
  } do
    start_channel!(config)

    payload = %{
      "event_id" => "evt-1",
      "source" => "github",
      "sender_id" => "42",
      "text" => "Build finished."
    }

    assert {:ok, %{status: :accepted, session_id: "webhook_github_42"}} =
             Webhook.ingest(payload, token: token)

    assert_receive {:ensure_session, "webhook_github_42"}
    assert_receive {:process_input, "webhook_github_42", "Build finished."}
  end

  test "rejects webhook without valid token when token_env is configured", %{
    base_config: config,
    token: token
  } do
    start_channel!(config)

    assert {:error, :unauthorized} = Webhook.ingest(%{"text" => "unauthorized"})

    assert {:ok, %{status: :accepted}} =
             Webhook.ingest(%{"text" => "authorized"}, token: token)
  end

  test "ignores duplicated event_id without processing input twice", %{
    base_config: config,
    token: token
  } do
    start_channel!(config)

    payload = %{
      "event_id" => "evt-dup",
      "source" => "jenkins",
      "sender_id" => "91",
      "text" => "deploy ok"
    }

    assert {:ok, %{status: :accepted, session_id: "webhook_jenkins_91"}} =
             Webhook.ingest(payload, token: token)

    assert {:ok, %{status: :duplicate, session_id: "webhook_jenkins_91"}} =
             Webhook.ingest(payload, token: token)

    assert_receive {:process_input, "webhook_jenkins_91", "deploy ok"}
    refute_receive {:process_input, "webhook_jenkins_91", "deploy ok"}, 50
  end

  test "returns explicit error when payload has no textual content", %{
    base_config: config,
    token: token
  } do
    start_channel!(config)

    assert {:error, :invalid_payload} =
             Webhook.ingest(%{"event_id" => "evt-x", "source" => "ci"}, token: token)
  end

  defp start_channel!(config) do
    {:ok, pid} = Webhook.start_link(config)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    pid
  end
end
