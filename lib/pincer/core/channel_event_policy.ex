defmodule Pincer.Core.ChannelEventPolicy do
  @moduledoc """
  Centralizes small cross-channel decisions for visible status and error events.

  Channels still own transport primitives, but textual classification and
  user-facing error envelopes live in core.
  """

  @doc """
  Builds the visible error message for a channel-specific transport.
  """
  @spec error_message(atom(), String.t()) :: String.t()
  def error_message(:telegram, text) when is_binary(text), do: "❌ <b>Agent Error</b>: #{text}"
  def error_message(:discord, text) when is_binary(text), do: "❌ **Agent Error**: #{text}"
  def error_message(:whatsapp, text) when is_binary(text), do: "Agent error: #{text}"
  def error_message(_channel, text) when is_binary(text), do: "Agent error: #{text}"

  @doc """
  Builds the approval-request message for a channel-specific transport.

  Returns a channel-formatted string that the channel session can send verbatim.
  The command is embedded as a code block using each channel's native syntax.
  """
  @spec approval_message(atom(), String.t()) :: String.t()
  def approval_message(:telegram, command),
    do: "<b>⚠️ Aprovação necessária</b>\n\nO agente quer executar:\n<pre>#{command}</pre>"

  def approval_message(:discord, command),
    do: "**⚠️ Aprovação necessária**\n\nO agente quer executar:\n```\n#{command}\n```"

  def approval_message(_channel, command),
    do:
      "⚠️ Aprovação necessária\n\nO agente quer executar:\n#{command}\n\nResponda Aprovo ou Rejeito."

  @doc """
  Classifies a status string so channel workers can route it without owning
  textual heuristics.
  """
  @spec status_kind(String.t()) :: :plain | :subagent
  def status_kind(text) when is_binary(text) do
    if String.contains?(text, "Sub-Agent"), do: :subagent, else: :plain
  end
end
