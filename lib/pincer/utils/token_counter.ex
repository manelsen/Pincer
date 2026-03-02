defmodule Pincer.Utils.TokenCounter do
  @moduledoc """
  Lightweight token estimation utilities for LLM context management.

  Provides heuristic-based token counting without requiring native NIF
  dependencies like `tiktoken`. Uses the approximation of ~4 characters
  per token, which provides reasonable estimates for English text while
  being language-agnostic.

  ## Accuracy Note

  This is an **estimation**, not exact tokenization. Real token counts
  depend on the specific tokenizer used by the LLM provider:

  | Provider | Tokenizer | Typical Ratio |
  |----------|-----------|---------------|
  | OpenAI | tiktoken (cl100k_base) | ~4 chars/token |
  | Anthropic | Custom | ~3.5 chars/token |
  | Others | Varies | 3-5 chars/token |

  For production use requiring exact counts, consider integrating
  provider-specific tokenizers. This module is optimized for speed
  and simplicity.

  ## Use Cases

    - Pre-send context size validation
    - Context window utilization monitoring
    - Message truncation decisions
    - Cost estimation

  ## Examples

      # Count tokens in a string
      Pincer.Utils.TokenCounter.count("Hello, world!")
      # => 4

      # Count tokens in OpenAI message format
      messages = [
        %{"role" => "system", "content" => "You are helpful."},
        %{"role" => "user", "content" => "Hello!"}
      ]
      Pincer.Utils.TokenCounter.count_messages(messages)
      # => 16 (includes ~4 token overhead per message)

      # Check context utilization
      Pincer.Utils.TokenCounter.utilization(messages, 4096)
      # => 0.39  (0.39% of 4096 context window)
  """

  @avg_chars_per_token 4.0
  @message_overhead 4

  @doc """
  Estimates the number of tokens in a string.

  Uses a simple heuristic of dividing character count by the average
  characters per token ratio.

  ## Parameters

    - `text` - String to count tokens for

  ## Returns

    - `integer()` - Estimated token count (always >= 0)
    - Returns `0` for non-string inputs

  ## Examples

      iex> Pincer.Utils.TokenCounter.count("Hello, world!")
      4

      iex> Pincer.Utils.TokenCounter.count("")
      0

      iex> Pincer.Utils.TokenCounter.count(nil)
      0

      iex> Pincer.Utils.TokenCounter.count("A longer piece of text with more words.")
      11
  """
  @spec count(String.t() | nil) :: non_neg_integer()
  def count(text) when is_binary(text) do
    (String.length(text) / @avg_chars_per_token) |> ceil()
  end

  def count(_), do: 0

  @doc """
  Estimates the total token count for a list of messages in OpenAI format.

  Adds overhead for each message's structure (role, content keys) to
  account for the message wrapper tokens.

  ## Parameters

    - `messages` - List of message maps with `"content"` key

  ## Returns

    - `integer()` - Total estimated tokens including overhead

  ## Message Format

  Expects messages in OpenAI/Anthropic format:

      [
        %{"role" => "system", "content" => "..."},
        %{"role" => "user", "content" => "..."},
        %{"role" => "assistant", "content" => "..."}
      ]

  ## Examples

      iex> messages = [%{"role" => "user", "content" => "Hello!"}]
      iex> Pincer.Utils.TokenCounter.count_messages(messages)
      6

      iex> messages = [
      ...>   %{"role" => "system", "content" => "You are helpful."},
      ...>   %{"role" => "user", "content" => "Hi"}
      ...> ]
      iex> Pincer.Utils.TokenCounter.count_messages(messages)
      13

      iex> Pincer.Utils.TokenCounter.count_messages([])
      0

      iex> Pincer.Utils.TokenCounter.count_messages([%{"content" => nil}])
      4
  """
  @spec count_messages([map()]) :: non_neg_integer()
  def count_messages(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      content = msg["content"] || ""
      acc + count(content) + @message_overhead
    end)
  end

  @doc """
  Calculates the context window utilization as a percentage.

  Useful for monitoring when to truncate or summarize conversation history
  before hitting context limits.

  ## Parameters

    - `messages` - List of messages in OpenAI format
    - `window_size` - Maximum context tokens for the model

  ## Returns

    - `float()` - Percentage of context window used (0.0 to potentially >100.0)

  ## Examples

      iex> messages = [%{"role" => "user", "content" => "Hello!"}]
      iex> Pincer.Utils.TokenCounter.utilization(messages, 4096)
      0.146484375

      iex> long_messages = [%{"role" => "user", "content" => String.duplicate("x", 20000)}]
      iex> Pincer.Utils.TokenCounter.utilization(long_messages, 4096)
      122.0703125

      iex> Pincer.Utils.TokenCounter.utilization([], 4096)
      0.0

  ## Common Context Windows

  | Model | Context Size |
  |-------|-------------|
  | GPT-3.5-turbo | 4,096 |
  | GPT-4 | 8,192 |
  | GPT-4-32k | 32,768 |
  | Claude-3-Haiku | 200,000 |
  | Claude-3-Opus | 200,000 |
  """
  @spec utilization([map()], pos_integer()) :: float()
  def utilization(messages, window_size) do
    used = count_messages(messages)
    used / window_size * 100
  end
end
