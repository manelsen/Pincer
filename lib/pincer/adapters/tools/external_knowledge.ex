defmodule Pincer.Adapters.Tools.ExternalKnowledge do
  @moduledoc """
  Tool to ingest and search external knowledge (APIs, Languages, Docs).
  Connects to the vector store (SQLite Vector Stopgap / LanceDB).
  """
  @behaviour Pincer.Ports.Tool
  alias Pincer.Ports.Storage
  alias Pincer.Ports.LLM

  @impl true
  def spec do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "ingest_external_knowledge",
          "description" => "Ingests a piece of external knowledge (like documentation, release notes, or code examples) into the long-term vector memory. Use this after researching new technologies (like Gleam or Go 1.26) via GitHub or Web.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "source" => %{
                "type" => "string",
                "description" => "The source of the information (e.g., 'GitHub: odin-lang/Odin', 'Gleam Docs')."
              },
              "content" => %{
                "type" => "string",
                "description" => "The actual text content to memorize."
              }
            },
            "required" => ["source", "content"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "search_external_knowledge",
          "description" => "Searches the external knowledge base for information about APIs, languages, or documentation previously ingested.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "query" => %{
                "type" => "string",
                "description" => "The semantic search query."
              },
              "limit" => %{
                "type" => "integer",
                "default" => 5
              }
            },
            "required" => ["query"]
          }
        }
      }
    ]
  end

  @impl true
  def execute(%{"tool_name" => "ingest_external_knowledge", "source" => source, "content" => content}) do
    case LLM.generate_embedding(content, provider: "openrouter") do
      {:ok, vector} ->
        case Storage.index_document(source, content, vector) do
          :ok -> {:ok, "Successfully ingested knowledge from '#{source}' into the vector store."}
          {:error, reason} -> {:error, "Storage failure: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Embedding generation failed: #{inspect(reason)}"}
    end
  end

  @impl true
  def execute(%{"tool_name" => "search_external_knowledge", "query" => query} = args) do
    limit = Map.get(args, "limit", 5)

    case LLM.generate_embedding(query, provider: "openrouter") do
      {:ok, vector} ->
        case Storage.search_similar("document", vector, limit) do
          {:ok, results} ->
            if results == [] do
              {:ok, "No relevant external knowledge found for '#{query}'."}
            else
              formatted = Enum.map_join(results, "\n---\n", & &1.content)
              {:ok, "Found relevant knowledge:\n\n#{formatted}"}
            end

          {:error, reason} ->
            {:error, "Search failure: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Embedding generation failed: #{inspect(reason)}"}
    end
  end
end
