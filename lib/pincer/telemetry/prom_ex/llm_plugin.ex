defmodule Pincer.Telemetry.PromEx.LlmPlugin do
  @moduledoc "PromEx plugin for LLM provider metrics."
  use PromEx.Plugin

  @impl true
  def event_metrics(_opts) do
    [
      Event.build(
        :pincer_llm_request_duration_milliseconds,
        [
          counter(
            [:pincer, :llm, :request, :count],
            event_name: [:pincer, :llm, :request, :stop],
            description: "Total LLM requests",
            tags: [:provider, :model, :status]
          ),
          distribution(
            [:pincer, :llm, :request, :duration, :milliseconds],
            event_name: [:pincer, :llm, :request, :stop],
            description: "LLM request latency in milliseconds",
            measurement: :duration,
            unit: {:native, :millisecond},
            tags: [:provider, :model],
            reporter_options: [buckets: [100, 500, 1000, 3000, 10_000, 30_000]]
          )
        ]
      ),
      Event.build(
        :pincer_llm_tokens,
        [
          counter(
            [:pincer, :llm, :tokens, :prompt, :total],
            event_name: [:pincer, :llm, :tokens],
            description: "Total prompt tokens consumed",
            measurement: :prompt_tokens,
            tags: [:provider, :model]
          ),
          counter(
            [:pincer, :llm, :tokens, :completion, :total],
            event_name: [:pincer, :llm, :tokens],
            description: "Total completion tokens produced",
            measurement: :completion_tokens,
            tags: [:provider, :model]
          )
        ]
      ),
      Event.build(
        :pincer_llm_errors,
        [
          counter(
            [:pincer, :llm, :error, :count],
            event_name: [:pincer, :llm, :error],
            description: "LLM request errors",
            tags: [:provider, :error_class]
          )
        ]
      )
    ]
  end
end
