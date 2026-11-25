defmodule Pincer.Channels.Telegram.ResponseEnvelope do
  @moduledoc """
  Response-envelope formatting and delivery options for Telegram channel output.

  Lives inside `pincer_telegram` so Telegram HTML rendering stays decoupled from
  `Pincer.Core`.
  """

  alias PincerPorts.Structs.Usage

  @doc """
  Builds final Telegram message text, optionally appending an HTML usage footer.
  """
  @spec build(String.t() | nil, Usage.t() | map() | nil, String.t() | nil) :: String.t()
  def build(text, usage, usage_display) do
    normalize_text(text) <> usage_line(usage, usage_display)
  end

  @doc """
  Extracts Telegram delivery options from the session status map.
  """
  @spec delivery_options(map()) :: keyword()
  def delivery_options(%{reasoning_visible: true}), do: [skip_reasoning_strip: true]
  def delivery_options(_session_status), do: []

  defp usage_line(nil, _display), do: ""
  defp usage_line(_usage, "off"), do: ""

  defp usage_line(usage, "tokens") when is_map(usage) do
    %Usage{prompt_tokens: in_t, completion_tokens: out_t} = Usage.normalize(usage)
    "\n\n<i>📊 #{in_t} in · #{out_t} out</i>"
  end

  defp usage_line(usage, "full") when is_map(usage) do
    %Usage{total_tokens: total} = Usage.normalize(usage)
    "\n\n<i>📊 total: #{total} tokens</i>"
  end

  defp usage_line(_usage, _display), do: ""

  defp normalize_text(nil), do: ""
  defp normalize_text(text), do: to_string(text)
end
