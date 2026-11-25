defmodule Pincer.Channels.Shared.Formatting do
  @moduledoc """
  Shared reasoning cleanup and channel message formatting helpers.
  """

  @default_safe_tags ~w(b i u s strong em strike del a blockquote)
  @file_extensions ~w(md go py pl sh am at be cc)
  @file_extension_pattern ~r/(^|[^a-zA-Z0-9_\-\/])([a-zA-Z0-9_.\-\.\/]+\.(?:#{Enum.join(@file_extensions, "|")}))(?=$|[^a-zA-Z0-9_\-\/])/i

  @doc """
  Removes user-invisible reasoning blocks from a response while preserving
  the externally visible answer text.
  """
  @spec strip_reasoning(term()) :: term()
  def strip_reasoning(nil), do: nil

  def strip_reasoning(text) when is_binary(text) do
    text
    |> String.replace(~r/<(?:thought|thinking)\b[^>]*>[\s\S]*?<\/(?:thought|thinking)>/i, "")
    |> String.replace(~r/\A\s*<(?:thought|thinking)\b[^>]*>[\s\S]*\z/i, "")
    |> String.replace(~r/^think>.*?(?:\n\n|\r\n\r\n|$)/is, "")
    |> String.trim()
  end

  def strip_reasoning(other), do: other

  @doc """
  Formats reasoning blocks for HTML-capable channels while preserving the final answer.
  """
  @spec format_reasoning_html(term()) :: term()
  def format_reasoning_html(nil), do: nil

  def format_reasoning_html(text) when is_binary(text) do
    text
    |> then(fn current ->
      Regex.replace(~r/<thought>([\s\S]*?)<\/thought>/i, current, &reasoning_block_html/1,
        global: true
      )
    end)
    |> then(fn current ->
      Regex.replace(~r/<thinking>([\s\S]*?)<\/thinking>/i, current, &reasoning_block_html/1,
        global: true
      )
    end)
    |> then(fn current ->
      Regex.replace(~r/^.*?think>\s*([\s\S]*)$/i, current, &reasoning_block_html/1)
    end)
  end

  def format_reasoning_html(other), do: other

  @doc """
  Applies reasoning visibility policy according to `:skip_reasoning_strip`.
  """
  @spec format_reasoning(term(), keyword()) :: term()
  def format_reasoning(text, opts \\ []) when is_list(opts) do
    if Keyword.get(opts, :skip_reasoning_strip, false) do
      format_reasoning_html(text)
    else
      strip_reasoning(text)
    end
  end

  @doc """
  Protects literal HTML `<pre>`, `<code>`, and safe inline tags with placeholders
  so a Markdown parser does not escape existing HTML.
  """
  @spec fence_html(String.t(), keyword()) :: {String.t(), map()}
  def fence_html(text, opts \\ []) when is_binary(text) and is_list(opts) do
    safe_tags = Keyword.get(opts, :safe_tags, @default_safe_tags)

    {fenced, map} =
      Regex.scan(~r/<(pre|code)(?:\s+[^>]*?)?>(.*?)<\/\1>/is, text)
      |> Enum.reduce({text, %{}}, fn [full, tag, content], {t, m} ->
        placeholder = "⦓B#{map_size(m)}⦔"
        content = "<#{tag}>#{content}</#{tag}>"
        {String.replace(t, full, placeholder), Map.put(m, placeholder, content)}
      end)

    Enum.reduce(safe_tags, {fenced, map}, fn tag, {acc_text, acc_map} ->
      {acc_text, acc_map} = fence_tag_matches(acc_text, acc_map, ~r/<#{tag}(?:\s+[^>]*?)?>/i)
      fence_tag_matches(acc_text, acc_map, ~r/<\/#{tag}>/i)
    end)
  end

  @doc """
  Restores fenced HTML placeholders produced by `fence_html/2`.
  """
  @spec unfence_html(String.t(), map()) :: String.t()
  def unfence_html(rendered, fenced_map) when is_binary(rendered) and is_map(fenced_map) do
    Enum.reduce(fenced_map, rendered, fn {placeholder, content}, acc ->
      String.replace(acc, placeholder, content)
    end)
  end

  @doc """
  Wraps recognized filenames (for example `README.md` or `main.go`) in `<code>`
  tags so messaging clients do not turn them into link previews.
  """
  @spec wrap_file_references(String.t(), keyword()) :: String.t()
  def wrap_file_references(html, opts \\ []) when is_binary(html) and is_list(opts) do
    pattern =
      case Keyword.get(opts, :extensions) do
        nil ->
          @file_extension_pattern

        extensions when is_list(extensions) ->
          ~r/(^|[^a-zA-Z0-9_\-\/])([a-zA-Z0-9_.\-\.\/]+\.(?:#{Enum.join(extensions, "|")}))(?=$|[^a-zA-Z0-9_\-\/])/i
      end

    Regex.replace(pattern, html, fn _full, prefix, filename ->
      "#{prefix}<code>#{filename}</code>"
    end)
  end

  @doc """
  Runs hybrid HTML fencing, optional Markdown AST rendering via `:render_markdown`,
  unfencing, optional file reference wrapping, and trims the result.
  """
  @spec markdown_to_html(String.t() | nil, keyword()) :: String.t()
  def markdown_to_html(text, opts \\ [])
  def markdown_to_html(nil, _opts), do: ""

  def markdown_to_html(text, opts) when is_binary(text) and is_list(opts) do
    render_markdown = Keyword.get(opts, :render_markdown, & &1)
    wrap_files? = Keyword.get(opts, :wrap_file_references, true)

    prepared = String.replace(text, "\r\n", "\n")
    {fenced, map} = fence_html(prepared, opts)

    restored =
      fenced
      |> render_markdown.()
      |> unfence_html(map)

    final_html =
      if wrap_files? do
        wrap_file_references(restored, opts)
      else
        restored
      end

    String.trim(final_html)
  end

  @doc """
  Converts HTML-formatted channel text into plain text for fallback delivery
  when an upstream API rejects HTML entities.
  """
  @spec html_to_plain_text(String.t() | nil) :: String.t() | nil
  def html_to_plain_text(nil), do: nil

  def html_to_plain_text(html) when is_binary(html) do
    html
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<[^>]+>/, "")
  end

  @doc """
  Normalizes Pincer Markdown for Discord by stripping hidden reasoning blocks
  and trimming whitespace.
  """
  @spec markdown_to_discord(String.t() | nil) :: String.t()
  def markdown_to_discord(nil), do: ""

  def markdown_to_discord(text) when is_binary(text) do
    text
    |> strip_reasoning()
    |> String.trim()
  end

  @doc """
  Converts standard Markdown constructs into Slack `mrkdwn` syntax.
  """
  @spec markdown_to_mrkdwn(String.t() | nil) :: String.t()
  def markdown_to_mrkdwn(nil), do: ""

  def markdown_to_mrkdwn(text) when is_binary(text) do
    text
    |> String.replace(~r/\*\*(.*?)\*\*/, "*\\1*")
    |> String.replace(~r/__(.*?)__/, "_\\1_")
    |> String.replace(~r/\[(.*?)\]\((.*?)\)/, "<\\2|\\1>")
  end

  defp fence_tag_matches(acc_text, acc_map, regex) do
    Regex.scan(regex, acc_text)
    |> Enum.uniq()
    |> Enum.reduce({acc_text, acc_map}, fn [match], {t, m} ->
      placeholder = "⦓T#{map_size(m)}⦔"
      {String.replace(t, match, placeholder), Map.put(m, placeholder, match)}
    end)
  end

  defp reasoning_block_html([_full, body]), do: reasoning_block_html(body)

  defp reasoning_block_html(body) when is_binary(body) do
    escaped =
      body
      |> String.trim()
      |> html_escape()

    "<b>💭 Reasoning</b>\n<i>#{escaped}</i>"
  end

  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
