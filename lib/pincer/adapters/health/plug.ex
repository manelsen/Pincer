defmodule Pincer.Adapters.Health.Plug do
  @moduledoc """
  HTTP health endpoint for load balancers and Kubernetes readiness probes.

  Exposes `GET /health` on port 4001 (configurable via `:pincer, :health_port`).

  ## Response

      {
        "status": "ok",
        "circuit_breakers": {
          "openrouter": "closed",
          "anthropic": "open"
        },
        "sessions": 3,
        "timestamp": "2026-04-10T08:00:00Z"
      }

  ## Configuration

      config :pincer, health_port: 4001

  ## Wire-up

  The plug is started via `Bandit` in `Pincer.Application`.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  @doc false
  get "/health" do
    body = Jason.encode!(build_status())
    conn = put_resp_content_type(conn, "application/json")
    send_resp(conn, 200, body)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # --- Private ---

  defp build_status do
    %{
      status: "ok",
      circuit_breakers: circuit_breaker_summary(),
      sessions: session_count(),
      timestamp: utc_timestamp()
    }
  end

  defp circuit_breaker_summary do
    Pincer.Core.CircuitBreaker.summary()
    |> Map.new(fn {name, state, _failures} -> {name, Atom.to_string(state)} end)
  end

  defp session_count do
    case DynamicSupervisor.count_children(Pincer.Core.Session.Supervisor) do
      %{active: count} -> count
    end
  end

  defp utc_timestamp do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
