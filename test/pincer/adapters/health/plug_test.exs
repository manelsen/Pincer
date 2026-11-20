defmodule Pincer.Adapters.Health.PlugTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn, only: [get_resp_header: 2]

  alias Pincer.Adapters.Health.Plug, as: HealthPlug

  @opts HealthPlug.init([])

  describe "GET /health" do
    test "returns 200 with JSON body" do
      conn = conn(:get, "/health") |> HealthPlug.call(@opts)

      assert conn.status == 200
    end

    test "responds with application/json content-type" do
      conn = conn(:get, "/health") |> HealthPlug.call(@opts)

      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end

    test "body contains status ok" do
      conn = conn(:get, "/health") |> HealthPlug.call(@opts)

      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
    end

    test "body contains sessions count" do
      conn = conn(:get, "/health") |> HealthPlug.call(@opts)

      body = Jason.decode!(conn.resp_body)
      assert is_integer(body["sessions"])
    end

    test "body contains circuit_breakers map" do
      conn = conn(:get, "/health") |> HealthPlug.call(@opts)

      body = Jason.decode!(conn.resp_body)
      assert is_map(body["circuit_breakers"])
    end

    test "body contains ISO 8601 timestamp" do
      conn = conn(:get, "/health") |> HealthPlug.call(@opts)

      body = Jason.decode!(conn.resp_body)
      assert is_binary(body["timestamp"])
      assert {:ok, _, _} = DateTime.from_iso8601(body["timestamp"])
    end
  end

  describe "unknown routes" do
    test "returns 404 for unknown path" do
      conn = conn(:get, "/unknown") |> HealthPlug.call(@opts)

      assert conn.status == 404
    end

    test "returns 404 for POST /health" do
      conn = conn(:post, "/health") |> HealthPlug.call(@opts)

      assert conn.status == 404
    end
  end

  describe "bind_ip/1" do
    test "defaults to loopback {127, 0, 0, 1}" do
      assert HealthPlug.bind_ip(health_ip: nil, env_fetcher: fn _ -> nil end) == {127, 0, 0, 1}
    end

    test "parses explicit IPv4 and IPv6 strings or tuples and falls back on invalid values" do
      assert HealthPlug.bind_ip(health_ip: "0.0.0.0") == {0, 0, 0, 0}
      assert HealthPlug.bind_ip(health_ip: "::1") == {0, 0, 0, 0, 0, 0, 0, 1}
      assert HealthPlug.bind_ip(health_ip: {127, 0, 0, 1}) == {127, 0, 0, 1}
      assert HealthPlug.bind_ip(health_ip: "not-an-ip") == {127, 0, 0, 1}

      assert HealthPlug.bind_ip(
               health_ip: nil,
               env_fetcher: fn
                 "PINCER_HEALTH_IP" -> "0.0.0.0"
                 _ -> nil
               end
             ) == {0, 0, 0, 0}
    end
  end
end
