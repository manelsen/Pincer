defmodule Pincer.Core.LLM.ModelRouter do
  @moduledoc """
  Complexity-based model routing inspired by ArgentOS.

  Scores request complexity (0.0–1.0) based on conversation depth, tool usage,
  message length, and technical content detection. Maps the score to a tier
  (local, fast, balanced, powerful) with associated provider/model.

  ## Scoring factors

    * Tool call density in recent messages (weight: 0.30)
    * Conversation depth (weight: 0.20)
    * Last user message length (weight: 0.20)
    * Code/technical content detection (weight: 0.30)

  ## Configuration (config.yaml)

      model_router:
        enabled: true
        tiers:
          local:    { provider: "groq",       model: "llama-3.3-70b-versatile" }
          fast:     { provider: "groq",       model: "llama-3.3-70b-versatile" }
          balanced: { provider: "z_ai",       model: "glm-4.7" }
          powerful: { provider: "z_ai_coding", model: "glm-4.7" }
  """

  @type tier :: :local | :fast | :balanced | :powerful

  @doc """
  Calculate a complexity score from 0.0 to 1.0 for the given history.
  """
  @spec score([map()], keyword()) :: float()
  def score(history, _opts \\ [])

  def score([], _opts), do: 0.0

  def score(history, _opts) do
    depth = depth_score(history)
    tools = tool_score(history)
    length = length_score(history)
    technical = technical_score(history)

    # Weighted sum
    depth * 0.20 + tools * 0.30 + length * 0.20 + technical * 0.30
  end

  @doc """
  Score complexity and return the recommended provider/model for the tier.

  Returns `{:ok, :default}` when the router is disabled, history is empty,
  or no tiers are configured.
  """
  @spec route([map()], keyword()) ::
          {:ok, tier(), String.t(), String.t()} | {:ok, :default}
  def route(history, opts \\ [])

  def route(_history, enabled: false), do: {:ok, :default}
  def route([], _opts), do: {:ok, :default}

  def route(history, opts) do
    tiers = Keyword.get(opts, :tiers, load_tiers())

    if tiers == %{} do
      {:ok, :default}
    else
      s = score(history)
      tier = score_to_tier(s)
      %{provider: provider, model: model} = Map.fetch!(tiers, tier)
      {:ok, tier, provider, model}
    end
  end

  # --- Scoring factors ---

  defp depth_score(history) do
    non_system = Enum.reject(history, &(&1["role"] == "system"))
    min(length(non_system) / 20.0, 1.0)
  end

  defp tool_score(history) do
    tool_count = Enum.count(history, &(&1["role"] == "tool"))
    total = length(history)
    if total == 0, do: 0.0, else: min(tool_count / max(total * 0.4, 1.0), 1.0)
  end

  defp length_score(history) do
    case Enum.filter(history, &(&1["role"] == "user")) |> List.last() do
      nil -> 0.0
      msg -> min(String.length(to_string(msg["content"] || "")) / 2000.0, 1.0)
    end
  end

  defp technical_score(history) do
    recent = Enum.take(history, -6)
    combined = Enum.map_join(recent, " ", &to_string(&1["content"] || ""))
    combined = String.downcase(combined)

    indicators = [
      ~r/defmodule/,
      ~r/defp?\s/,
      ~r/import\s/,
      ~r/\bfunction\b/,
      ~r/\bclass\s/,
      ~r/\bapi\b/,
      ~r/\berror\b/,
      ~r/\bbug\b/,
      ~r/\brefactor\b/,
      ~r/```/,
      ~r/\bTODO\b/
    ]

    matches = Enum.count(indicators, &Regex.match?(&1, combined))
    min(matches / 4.0, 1.0)
  end

  # --- Tier mapping ---

  defp score_to_tier(s) when s < 0.25, do: :local
  defp score_to_tier(s) when s < 0.45, do: :fast
  defp score_to_tier(s) when s < 0.65, do: :balanced
  defp score_to_tier(_s), do: :powerful

  defp load_tiers do
    case Application.get_env(:pincer, :model_router, %{}) do
      %{tiers: tiers} when is_map(tiers) ->
        tiers
        |> Enum.into(%{}, fn {k, v} ->
          {k, %{provider: v["provider"] || v[:provider], model: v["model"] || v[:model]}}
        end)

      _ ->
        %{}
    end
  end
end
