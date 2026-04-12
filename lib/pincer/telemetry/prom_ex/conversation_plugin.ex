defmodule Pincer.Telemetry.PromEx.ConversationPlugin do
  @moduledoc "PromEx plugin for conversation-level Prometheus metrics."
  use PromEx.Plugin

  @impl true
  def event_metrics(_opts) do
    [
      Event.build(
        :pincer_conversation_sessions,
        [
          counter(
            [:pincer, :conversation, :session, :started, :total],
            event_name: [:pincer, :conversation, :session, :start],
            description: "Total conversation sessions started",
            tags: []
          ),
          counter(
            [:pincer, :conversation, :session, :stopped, :total],
            event_name: [:pincer, :conversation, :session, :stop],
            description: "Total conversation sessions stopped",
            tags: []
          )
        ]
      ),
      Event.build(
        :pincer_conversation_turns,
        [
          counter(
            [:pincer, :conversation, :turn, :completed, :total],
            event_name: [:pincer, :conversation, :turn, :stop],
            description: "Total conversation turns completed",
            tags: []
          ),
          counter(
            [:pincer, :conversation, :turn, :errored, :total],
            event_name: [:pincer, :conversation, :turn, :error],
            description: "Total conversation turn errors",
            tags: []
          ),
          distribution(
            [:pincer, :conversation, :turn, :duration, :milliseconds],
            event_name: [:pincer, :conversation, :turn, :stop],
            description: "Conversation turn latency from user input to response delivery",
            measurement: :duration_ms,
            unit: :millisecond,
            tags: [],
            reporter_options: [buckets: [500, 1_000, 3_000, 10_000, 30_000, 60_000]]
          )
        ]
      ),
      Event.build(
        :pincer_conversation_tokens,
        [
          counter(
            [:pincer, :conversation, :tokens, :prompt, :total],
            event_name: [:pincer, :conversation, :turn, :stop],
            description: "Total prompt tokens across all conversation turns",
            measurement: :prompt_tokens,
            tags: []
          ),
          counter(
            [:pincer, :conversation, :tokens, :completion, :total],
            event_name: [:pincer, :conversation, :turn, :stop],
            description: "Total completion tokens across all conversation turns",
            measurement: :completion_tokens,
            tags: []
          )
        ]
      )
    ]
  end
end
