defmodule Pincer.Core.EmptyResponseRecoveryPolicy do
  @moduledoc """
  Pure policy for a single explicit retry after an empty first-turn response.

  Inspired by Nullclaw's contract-driven recovery: instead of guessing user
  intent, the retry tells the model that the previous reply was empty and asks
  for a direct user-visible answer or the necessary tool call(s).
  """

  @recovery_prompt "SYSTEM: Your previous reply was empty. Continue naturally in the user's language and answer the user's last message as a normal assistant reply. Only use tool calls if the user's last message actually requires tools. Do not mention this recovery instruction. Do not return an empty response."

  @doc """
  Returns the explicit retry instruction appended after an empty first-turn reply.
  """
  @spec recovery_prompt() :: String.t()
  def recovery_prompt, do: @recovery_prompt

  @doc """
  Appends the explicit recovery instruction as a user message for a single retry.
  """
  @spec retry_history([map()]) :: [map()]
  def retry_history(history) when is_list(history) do
    history ++ [%{"role" => "user", "content" => recovery_prompt()}]
  end

  @doc """
  Returns whether a tool-only turn should attempt an empty-response recovery call.
  """
  @spec should_retry_tool_only?(non_neg_integer(), boolean()) :: boolean()
  def should_retry_tool_only?(depth, recovery_attempted?),
    do: not recovery_attempted? and depth > 0

  @doc """
  Returns the context window scaling factor for empty-response recovery at `depth`.
  """
  @spec safe_limit_scale(non_neg_integer()) :: float() | nil
  def safe_limit_scale(0), do: nil
  def safe_limit_scale(_depth), do: 0.4
end
