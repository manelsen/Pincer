defmodule Pincer.LLM.StreamFallback do
  @moduledoc """
  Degrades a failed streaming request into a single-shot chat completion and
  rehydrates the reply as a one-chunk stream.

  The request itself is passed in as a closure so this module never re-enters
  the retry loop of `Pincer.LLM.Client`; telemetry stays with the caller.
  """

  require Logger

  alias Pincer.LLM.CooldownRouting

  @doc """
  Runs the chat-completion fallback for a failed stream.

  `request` is invoked once and must return the same shape as
  `Pincer.LLM.Client.chat_completion/2`. `on_error` receives the failure reason.
  """
  @spec stream_to_chat(
          atom(),
          term(),
          (-> {:ok, map(), term()} | {:error, term()}),
          (term() -> term())
        ) :: {:ok, [map()]} | {:error, term()}
  def stream_to_chat(:stream_completion, reason, request, on_error)
      when is_function(request, 0) do
    Logger.warning(
      "[CLIENT] Streaming unavailable (#{CooldownRouting.reason_label(reason)}). Falling back to single-shot completion."
    )

    case request.() do
      {:ok, message, _usage} ->
        {:ok, chat_message_to_chunks(message)}

      {:error, fallback_reason} ->
        on_error.(fallback_reason)
        {:error, fallback_reason}
    end
  end

  def stream_to_chat(_action, reason, _request, on_error) do
    on_error.(reason)
    {:error, reason}
  end

  @doc """
  Converts a chat-completion message into the chunk list a provider stream
  would have produced.
  """
  @spec chat_message_to_chunks(map() | term()) :: [map()]
  def chat_message_to_chunks(message) when is_map(message) do
    content =
      case message["content"] do
        text when is_binary(text) -> text
        _ -> ""
      end

    tool_calls = message["tool_calls"] || []

    delta = %{}
    delta = if content == "", do: delta, else: Map.put(delta, "content", content)

    delta =
      if is_list(tool_calls) and tool_calls != [] do
        Map.put(
          delta,
          "tool_calls",
          Enum.with_index(tool_calls)
          |> Enum.map(fn {tool_call, index} ->
            %{
              "index" => index,
              "id" => tool_call["id"],
              "function" => %{
                "name" => get_in(tool_call, ["function", "name"]) || "",
                "arguments" => get_in(tool_call, ["function", "arguments"]) || ""
              }
            }
          end)
        )
      else
        delta
      end

    [%{"choices" => [%{"delta" => delta}]}]
  end

  def chat_message_to_chunks(_), do: [%{"choices" => [%{"delta" => %{"content" => ""}}]}]
end
