defmodule Pincer.Telemetry.PromEx.ChannelPlugin do
  @moduledoc "PromEx plugin for channel-level metrics."
  use PromEx.Plugin

  @impl true
  def event_metrics(_opts) do
    [
      Event.build(
        :pincer_channel_messages,
        [
          counter(
            [:pincer, :channel, :message, :received, :count],
            event_name: [:pincer, :channel, :message, :received],
            description: "Messages received per channel",
            tags: [:channel_type]
          ),
          counter(
            [:pincer, :channel, :message, :sent, :count],
            event_name: [:pincer, :channel, :message, :sent],
            description: "Messages sent per channel",
            tags: [:channel_type]
          ),
          distribution(
            [:pincer, :channel, :response, :duration, :milliseconds],
            event_name: [:pincer, :channel, :response, :stop],
            description: "End-to-end response latency per channel",
            measurement: :duration,
            unit: {:native, :millisecond},
            tags: [:channel_type],
            reporter_options: [buckets: [200, 500, 1000, 3000, 10_000]]
          )
        ]
      )
    ]
  end
end
