defmodule Pincer.Core.Introspection.Mood do
  @moduledoc """
  Pure functions for the agent mood system.

  Mood is represented as two dimensions:
  - **valence** (`-1.0` to `+1.0`): negative ↔ positive affect
  - **arousal** (`0.0` to `1.0`): low activation ↔ high activation

  Three sources drive mood changes:
  1. **Outcome** — executor traces shift mood (success → positive, failure → negative + aroused)
  2. **Decay** — homeostatic drift toward neutral each tick
  3. **LLM blend** — the introspection LLM suggests mood values that are blended in
  """

  @type mood :: {float(), float()}

  @doc """
  Computes mood shift from an executor trace outcome.

  - `:success` nudges valence up and arousal up slightly
  - `:failure` nudges valence down and arousal up (frustration)
  """
  @spec from_outcome(:success | :failure, float(), float()) :: mood()
  def from_outcome(:success, valence, arousal) do
    {valence + 0.1, arousal + 0.05}
    |> clamp()
  end

  def from_outcome(:failure, valence, arousal) do
    {valence - 0.15, arousal + 0.1}
    |> clamp()
  end

  @doc """
  Decays mood toward neutral `{0.0, 0.0}` at the given rate (0.0–1.0).

  Each call moves valence and arousal `rate * 100%` closer to zero.
  Default rate is `0.1` (10% per tick).
  """
  @spec decay(float(), float(), float()) :: mood()
  def decay(valence, arousal, rate \\ 0.1) do
    {valence * (1.0 - rate), arousal * (1.0 - rate)}
    |> clamp()
  end

  @doc """
  Blends LLM-suggested mood with current values using a weighted average.

  Default weight is `0.3` (30% LLM influence, 70% current).
  """
  @spec blend_llm(float(), float(), float(), float(), float()) :: mood()
  def blend_llm(current_v, current_a, llm_v, llm_a, weight \\ 0.3) do
    keep = 1.0 - weight

    {current_v * keep + llm_v * weight, current_a * keep + llm_a * weight}
    |> clamp()
  end

  @doc """
  Clamps valence to `[-1.0, 1.0]` and arousal to `[0.0, 1.0]`.
  """
  @spec clamp(mood()) :: mood()
  def clamp({valence, arousal}) do
    {
      valence |> max(-1.0) |> min(1.0),
      arousal |> max(0.0) |> min(1.0)
    }
  end

  @doc """
  Returns a human-readable mood label based on valence/arousal quadrant.

  | Valence | Arousal | Label |
  |---------|---------|-------|
  | high    | high    | energized |
  | high    | low     | content |
  | low     | high    | frustrated |
  | low     | low     | subdued |
  | ~0      | ~0      | neutral |
  """
  @spec label(float(), float()) :: String.t()
  def label(valence, arousal) do
    cond do
      abs(valence) < 0.15 and arousal < 0.15 -> "neutral"
      valence >= 0.15 and arousal >= 0.3 -> "energized"
      valence >= 0.15 -> "content"
      valence <= -0.15 and arousal >= 0.3 -> "frustrated"
      valence <= -0.15 -> "subdued"
      arousal >= 0.3 -> "alert"
      true -> "neutral"
    end
  end
end
