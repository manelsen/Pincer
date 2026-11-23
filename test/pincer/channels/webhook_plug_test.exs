defmodule Pincer.Channels.WebhookPlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Pincer.Channels.Webhook.Plug
  alias Pincer.Channels.Webhook.RateLimiter

  @path "/webhook/message"
  @token "top-secret-token"
  @payload %{"event_id" => "evt-1", "text" => "Build finished."}

  defp opts(overrides \\ []) do
    Keyword.merge(
      [token: @token, path: @path, max_body_bytes: 1_048_576, ingest_fun: &default_ingest/2],
      overrides
    )
  end

  defp default_ingest(_payload, _opts) do
    {:ok, %{status: :accepted, session_id: "webhook_test_1"}}
  end

  defp json_request(body, headers \\ []) do
    conn(:post, @path, body)
    |> put_req_header("content-type", "application/json")
    |> apply_headers(headers)
  end

  defp apply_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
  end

  defp body(payload), do: Jason.encode!(payload)

  defp decode(conn) do
    assert conn.status != nil
    Jason.decode!(conn.resp_body)
  end

  test "returns 202 for an accepted payload and forwards payload, token and headers once" do
    parent = self()
    payload = @payload

    ingest = fn payload, opts ->
      send(parent, {:ingested, payload, opts})
      {:ok, %{status: :accepted, session_id: "webhook_github_42"}}
    end

    conn =
      json_request(body(payload), [{"x-pincer-token", @token}])
      |> Plug.call(opts(ingest_fun: ingest))

    assert conn.status == 202
    assert %{"status" => "accepted", "session_id" => "webhook_github_42"} = decode(conn)

    assert_receive {:ingested, ^payload, ingest_opts}
    assert ingest_opts[:token] == @token
    assert ingest_opts[:headers]["x-pincer-token"] == @token
    assert ingest_opts[:headers]["content-type"] =~ "application/json"

    refute_receive {:ingested, _, _}, 50
  end

  test "returns 200 for a duplicate payload" do
    ingest = fn _payload, _opts -> {:ok, %{status: :duplicate, session_id: "webhook_ci_7"}} end

    conn =
      json_request(body(@payload), [{"x-pincer-token", @token}])
      |> Plug.call(opts(ingest_fun: ingest))

    assert conn.status == 200
    assert %{"status" => "duplicate", "session_id" => "webhook_ci_7"} = decode(conn)
  end

  test "rejects missing, short, long and mismatched tokens with 401 before reading the body" do
    parent = self()

    ingest = fn payload, ingest_opts ->
      send(parent, {:ingested, payload, ingest_opts})
      {:ok, %{status: :accepted, session_id: "webhook_test_1"}}
    end

    for headers <- [
          [],
          [{"x-pincer-token", "short"}],
          [{"x-pincer-token", "top-secret-token-but-longer"}],
          [{"x-pincer-token", "top-secret-tokeX"}]
        ] do
      conn =
        json_request(body(@payload), headers)
        |> Plug.call(opts(ingest_fun: ingest))

      assert conn.status == 401
      assert %{"error" => _} = decode(conn)
    end

    # An oversized body without a token must be rejected as unauthorized,
    # proving authentication happens before the body is read.
    oversized = String.duplicate("a", 256)

    conn =
      json_request(oversized)
      |> Plug.call(opts(ingest_fun: ingest, max_body_bytes: 16))

    assert conn.status == 401
    refute_receive {:ingested, _, _}, 50
  end

  test "accepts Bearer authorization (case-insensitive) and raw authorization values" do
    for header_value <- ["Bearer #{@token}", "bearer #{@token}", @token] do
      conn =
        json_request(body(@payload), [{"authorization", header_value}])
        |> Plug.call(opts())

      assert conn.status == 202
    end
  end

  test "returns 415 for a non-JSON content type" do
    conn =
      conn(:post, @path, body(@payload))
      |> put_req_header("content-type", "text/plain")
      |> put_req_header("x-pincer-token", @token)
      |> Plug.call(opts())

    assert conn.status == 415
    assert %{"error" => _} = decode(conn)
  end

  test "accepts a JSON content type with a charset parameter" do
    conn =
      conn(:post, @path, body(@payload))
      |> put_req_header("content-type", "application/json; charset=utf-8")
      |> put_req_header("x-pincer-token", @token)
      |> Plug.call(opts())

    assert conn.status == 202
  end

  test "returns 400 for malformed JSON" do
    conn =
      json_request("{\"broken\":", [{"x-pincer-token", @token}])
      |> Plug.call(opts())

    assert conn.status == 400
    assert %{"error" => _} = decode(conn)
  end

  test "returns 400 when the JSON body is not a map" do
    conn =
      json_request("[1,2,3]", [{"x-pincer-token", @token}])
      |> Plug.call(opts())

    assert conn.status == 400
  end

  test "returns 413 for a body larger than max_body_bytes" do
    oversized = Jason.encode!(%{"text" => String.duplicate("x", 128)})

    conn =
      json_request(oversized, [{"x-pincer-token", @token}])
      |> Plug.call(opts(max_body_bytes: 32))

    assert conn.status == 413
    assert %{"error" => _} = decode(conn)
  end

  test "returns 404 for an unknown path" do
    conn =
      conn(:post, "/not-a-webhook", body(@payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-pincer-token", @token)
      |> Plug.call(opts())

    assert conn.status == 404
    assert %{"error" => _} = decode(conn)
  end

  test "accepts /webhook as a path alias" do
    conn =
      conn(:post, "/webhook", body(@payload))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-pincer-token", @token)
      |> Plug.call(opts())

    assert conn.status == 202
  end

  test "returns 405 for a non-POST method on the webhook path" do
    conn =
      conn(:get, @path)
      |> put_req_header("x-pincer-token", @token)
      |> Plug.call(opts())

    assert conn.status == 405
    assert %{"error" => _} = decode(conn)
  end

  test "maps ingest errors and unknown results to documented statuses" do
    cases = [
      {{:error, :unauthorized}, 401},
      {{:error, :invalid_payload}, 422},
      {{:error, :channel_unavailable}, 503},
      {{:error, :unexpected}, 500},
      {:not_a_valid_result, 500}
    ]

    for {result, expected_status} <- cases do
      ingest = fn _payload, _opts -> result end

      conn =
        json_request(body(@payload), [{"x-pincer-token", @token}])
        |> Plug.call(opts(ingest_fun: ingest))

      assert conn.status == expected_status
      assert %{"error" => _} = decode(conn)
    end
  end

  test "returns 429 with retry-after once the limiter rejects a request" do
    limiter = start_supervised!({RateLimiter, name: nil, limit: 1})

    accepted =
      json_request(body(@payload), [{"x-pincer-token", @token}])
      |> Plug.call(opts(rate_limiter: limiter))

    assert accepted.status == 202

    rejected =
      json_request(body(@payload), [{"x-pincer-token", @token}])
      |> Plug.call(opts(rate_limiter: limiter))

    assert rejected.status == 429
    assert %{"error" => "rate_limited"} = decode(rejected)

    assert [retry_after] = get_resp_header(rejected, "retry-after")
    assert {seconds, ""} = Integer.parse(retry_after)
    assert seconds >= 1
  end

  test "enforces the rate limit before authentication" do
    limiter = start_supervised!({RateLimiter, name: nil, limit: 2})

    unauthorized = fn ->
      json_request(body(@payload))
      |> Plug.call(opts(rate_limiter: limiter))
    end

    assert unauthorized.().status == 401
    assert unauthorized.().status == 401
    assert unauthorized.().status == 429
  end

  test "limits each client IP independently" do
    limiter = start_supervised!({RateLimiter, name: nil, limit: 1})

    first =
      json_request(body(@payload), [{"x-pincer-token", @token}])
      |> Plug.call(opts(rate_limiter: limiter))

    assert first.status == 202

    same_ip =
      json_request(body(@payload), [{"x-pincer-token", @token}])
      |> Plug.call(opts(rate_limiter: limiter))

    assert same_ip.status == 429

    other_ip =
      json_request(body(@payload), [{"x-pincer-token", @token}])
      |> Map.put(:remote_ip, {10, 0, 0, 2})
      |> Plug.call(opts(rate_limiter: limiter))

    assert other_ip.status == 202
  end

  test "resets the window using the limiter clock" do
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    limiter =
      start_supervised!(
        {RateLimiter, name: nil, limit: 1, now_fun: fn -> Agent.get(clock, & &1) end}
      )

    request = fn ->
      json_request(body(@payload), [{"x-pincer-token", @token}])
      |> Plug.call(opts(rate_limiter: limiter))
    end

    assert request.().status == 202
    assert request.().status == 429

    Agent.update(clock, fn _now -> 60_000 end)

    assert request.().status == 202
  end

  test "bypasses limiting when no limiter is configured" do
    for _ <- 1..5 do
      conn =
        json_request(body(@payload), [{"x-pincer-token", @token}])
        |> Plug.call(opts(rate_limiter: nil))

      assert conn.status == 202
    end
  end

  test "fails closed with 503 when the limiter process is unavailable" do
    limiter = spawn(fn -> :ok end)
    ref = Process.monitor(limiter)
    assert_receive {:DOWN, ^ref, :process, ^limiter, _reason}

    conn =
      json_request(body(@payload), [{"x-pincer-token", @token}])
      |> Plug.call(opts(rate_limiter: limiter))

    assert conn.status == 503
    assert %{"error" => "rate_limiter_unavailable"} = decode(conn)
  end
end
