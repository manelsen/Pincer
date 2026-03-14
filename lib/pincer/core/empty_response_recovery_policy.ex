defmodule Pincer.Core.EmptyResponseRecoveryPolicy do
  @moduledoc """
  Pure policy for deciding whether an empty-response fallback may use a
  lightweight chat retry.

  The retry is reserved for low-risk smalltalk turns so factual requests do not
  get an invented answer from a second-pass model completion.
  """

  @smalltalk_patterns [
    ~r/^\s*(oi|ola|olá|e ai|e aí|hey|hi|hello)\s*[!.?]*\s*$/iu,
    ~r/^\s*(bom dia|boa tarde|boa noite)\s*[!.?]*\s*$/iu,
    ~r/^\s*(tudo bom|tudo bem|como vai|como voce esta|como você está|td bem)(\s+contigo)?\s*[?.!]*\s*$/iu
  ]

  @doc """
  Returns true when a lightweight chat retry is safe enough after an empty
  streaming response.
  """
  @spec allow_chat_retry?([map()]) :: boolean()
  def allow_chat_retry?(history) when is_list(history) do
    case last_user_text(history) do
      nil -> false
      text -> Enum.any?(@smalltalk_patterns, &Regex.match?(&1, text))
    end
  end

  defp last_user_text(history) do
    history
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"role" => "user", "content" => text} when is_binary(text) -> String.trim(text)
      _ -> nil
    end)
  end
end
