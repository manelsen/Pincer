defmodule Pincer.Telemetry.PromEx do
  @moduledoc """
  PromEx plugin module exposing Prometheus metrics for Pincer.
  Tracks LLM latency, error rates, token usage, and channel activity.
  """
  use PromEx, otp_app: :pincer

  alias PromEx.Plugins

  @impl true
  def plugins do
    [
      Plugins.Application,
      Plugins.Beam,
      Pincer.Telemetry.PromEx.LlmPlugin,
      Pincer.Telemetry.PromEx.ChannelPlugin,
      Pincer.Telemetry.PromEx.ConversationPlugin
    ]
  end

  @impl true
  def dashboard_assigns do
    [
      datasource_id: "Prometheus",
      default_selected_interval: "30s"
    ]
  end

  @impl true
  def dashboards do
    [{:prom_ex, "application.json"}]
  end
end
