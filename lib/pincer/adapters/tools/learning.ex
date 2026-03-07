defmodule Pincer.Adapters.Tools.Learning do
  @moduledoc """
  Tool for the agent to explicitly log learnings, best practices, and corrections.
  """
  @behaviour Pincer.Ports.Tool

  @impl true
  def spec do
    %{
      "type" => "function",
      "function" => %{
        "name" => "record_learning",
        "description" => "Record a new learning, best practice, or user correction into the permanent Graph Knowledge Base. Use this whenever the user corrects you, or you discover a better way to do something.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "category" => %{
              "type" => "string",
              "enum" => ["correction", "best_practice", "knowledge_gap"],
              "description" => "The type of learning."
            },
            "summary" => %{
              "type" => "string",
              "description" => "A concise summary of what was learned or corrected. Start with an action verb."
            }
          },
          "required" => ["category", "summary"]
        }
      }
    }
  end

  @impl true
  def execute(%{"category" => cat, "summary" => sum}) do
    case Pincer.Ports.Storage.save_learning(cat, sum) do
      {:ok, _} -> {:ok, "Learning successfully recorded and will be injected into future sessions."}
      {:error, e} -> {:error, "Failed to record learning: #{inspect(e)}"}
    end
  end
end
