defmodule Pincer.Core.Trace do
  @moduledoc """
  Structured execution trace envelope for session turns.

  Trace data is built as an append-only list of typed steps, then serialized
  into checkpoint metadata for persistence.
  """

  @typedoc "Allowed trace step kinds for core execution surfaces."
  @type step_kind :: :policy | :llm | :tool | :memory | :checkpoint | :error

  @type step :: %{
          kind: step_kind(),
          name: String.t(),
          details: map(),
          at: DateTime.t()
        }

  @type t :: %{
          trace_id: String.t(),
          session_id: String.t(),
          turn_id: String.t(),
          steps: [step()],
          metadata: map()
        }

  @doc """
  Creates a new trace envelope for a given session + turn.
  """
  @spec new(String.t(), String.t(), map()) :: t()
  def new(session_id, turn_id, metadata \\ %{})
      when is_binary(session_id) and is_binary(turn_id) do
    %{
      trace_id: Ecto.UUID.generate(),
      session_id: session_id,
      turn_id: turn_id,
      steps: [],
      metadata: metadata
    }
  end

  @doc """
  Appends one trace step to the envelope.
  """
  @spec add_step(t(), step_kind(), String.t(), map(), DateTime.t()) :: t()
  def add_step(trace, kind, name, details, at \\ DateTime.utc_now())
      when is_map(trace) and is_atom(kind) and is_binary(name) and is_map(details) do
    step = %{kind: kind, name: name, details: details, at: at}
    Map.update!(trace, :steps, &(&1 ++ [step]))
  end

  @doc """
  Encodes trace envelope for checkpoint metadata persistence.
  """
  @spec to_checkpoint_metadata(t()) :: map()
  def to_checkpoint_metadata(trace) when is_map(trace) do
    serialized_steps =
      Enum.map(Map.get(trace, :steps, []), fn step ->
        %{
          "kind" => step.kind |> to_string(),
          "name" => step.name,
          "details" => step.details,
          "at" => DateTime.to_iso8601(step.at)
        }
      end)

    %{
      "trace" => %{
        "trace_id" => trace.trace_id,
        "session_id" => trace.session_id,
        "turn_id" => trace.turn_id,
        "metadata" => trace.metadata,
        "steps" => serialized_steps
      }
    }
  end
end
