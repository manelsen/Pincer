defmodule Pincer.Telemetry.Otel do
  @moduledoc """
  OpenTelemetry instrumentation for Pincer.
  """
  require OpenTelemetry.Tracer, as: Tracer

  @doc "Start a span for tool execution."
  def start_tool_span(tool_name, risk_class) do
    Tracer.start_span("tool.execute", %{
      attributes: [
        {"tool.name", tool_name},
        {"tool.risk_class", to_string(risk_class)}
      ]
    })
  end

  @doc "Finish a span with ok or error status."
  def finish_span(ctx, :ok) do
    Tracer.set_status(ctx, :ok)
    Tracer.end_span(ctx)
  end

  def finish_span(ctx, {:error, _reason}) do
    Tracer.set_status(ctx, :error)
    Tracer.end_span(ctx)
  end

  def finish_span(ctx, _), do: Tracer.end_span(ctx)

  @doc "Emit telemetry event for LLM token usage."
  def emit_token_usage(provider, model, prompt_tokens, completion_tokens) do
    :telemetry.execute(
      [:pincer, :llm, :usage],
      %{prompt_tokens: prompt_tokens, completion_tokens: completion_tokens},
      %{provider: provider, model: model}
    )
  end
end
