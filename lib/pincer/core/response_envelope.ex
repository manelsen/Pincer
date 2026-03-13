defmodule Pincer.Core.ResponseEnvelope do
  @moduledoc """
  Pure response-envelope policy for channel-facing final text and delivery flags.

  This module does not perform transport or session lookups. It only turns
  channel, response text, usage data, and session preferences into deterministic
  output consumed by channel adapters.
  """

  @spec build(atom(), String.t() | nil, map() | nil, String.t() | nil) :: String.t()
  def build(channel, text, usage, usage_display) do
    normalize_text(text) <> usage_line(channel, usage, usage_display)
  end

  @spec delivery_options(atom(), map()) :: keyword()
  def delivery_options(:telegram, %{reasoning_visible: true}), do: [skip_reasoning_strip: true]
  def delivery_options(:telegram, _session_status), do: []
  def delivery_options(_channel, _session_status), do: []

  defp usage_line(:telegram, nil, _display), do: ""
  defp usage_line(:telegram, _usage, "off"), do: ""

  defp usage_line(:telegram, usage, "tokens") when is_map(usage) do
    in_t = usage["prompt_tokens"] || 0
    out_t = usage["completion_tokens"] || 0
    "\n\n<i>📊 #{in_t} in · #{out_t} out</i>"
  end

  defp usage_line(:telegram, usage, "full") when is_map(usage) do
    total = (usage["prompt_tokens"] || 0) + (usage["completion_tokens"] || 0)
    "\n\n<i>📊 total: #{total} tokens</i>"
  end

  defp usage_line(_channel, _usage, _display), do: ""

  defp normalize_text(nil), do: ""
  defp normalize_text(text), do: to_string(text)
end
