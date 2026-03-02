defmodule Pincer.Adapters.Tools.WebVisibility do
  @moduledoc """
  Utilities to sanitize HTML visibility before extracting text for LLM context.

  The goal is to reduce indirect prompt-injection vectors that rely on hidden
  DOM content and invisible Unicode control characters.
  """

  @hidden_class_pattern ~r/\b(?:sr-only|visually-hidden|d-none|hidden|invisible|screen-reader-only|offscreen)\b/i

  @invisible_unicode_re ~r/[\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{206A}-\x{206F}\x{FEFF}]/u
  @invisible_tag_re ~r/[\x{E0000}-\x{E007F}]/u

  @doc """
  Removes common hidden DOM patterns and HTML comments from an HTML string.
  """
  @spec sanitize_html(String.t()) :: String.t()
  def sanitize_html(html) when is_binary(html) do
    html
    |> strip_comments()
    |> strip_always_hidden_tags()
    |> strip_hidden_attr()
    |> strip_aria_hidden()
    |> strip_hidden_classes()
    |> strip_hidden_styles()
  end

  @doc """
  Removes invisible Unicode control characters often used in prompt-injection obfuscation.
  """
  @spec strip_invisible_unicode(String.t()) :: String.t()
  def strip_invisible_unicode(text) when is_binary(text) do
    text
    |> String.replace(@invisible_unicode_re, "")
    |> String.replace(@invisible_tag_re, "")
  end

  defp strip_comments(html), do: Regex.replace(~r/<!--[\s\S]*?-->/u, html, "")

  defp strip_always_hidden_tags(html) do
    html
    |> then(&Regex.replace(~r/<(?:meta)\b[^>]*\/?>/isu, &1, ""))
    |> then(
      &Regex.replace(
        ~r/<(?:template|svg|canvas|iframe|object|embed)\b[^>]*>.*?<\/(?:template|svg|canvas|iframe|object|embed)>/isu,
        &1,
        ""
      )
    )
    |> then(&Regex.replace(~r/<input\b[^>]*\btype\s*=\s*(["'])?hidden\1?[^>]*\/?>/isu, &1, ""))
  end

  defp strip_hidden_attr(html) do
    Regex.replace(
      ~r/<([a-zA-Z][\w:-]*)\b[^>]*\bhidden(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?[^>]*>.*?<\/\1>/isu,
      html,
      ""
    )
  end

  defp strip_aria_hidden(html) do
    Regex.replace(
      ~r/<([a-zA-Z][\w:-]*)\b[^>]*\baria-hidden\s*=\s*(["'])true\2[^>]*>.*?<\/\1>/isu,
      html,
      ""
    )
  end

  defp strip_hidden_classes(html) do
    Regex.replace(
      ~r/<([a-zA-Z][\w:-]*)\b[^>]*\bclass\s*=\s*(["'])(.*?)\2[^>]*>.*?<\/\1>/isu,
      html,
      fn full, _tag, _quote, class_value ->
        if Regex.match?(@hidden_class_pattern, class_value) do
          ""
        else
          full
        end
      end
    )
  end

  defp strip_hidden_styles(html) do
    Enum.reduce(style_hidden_patterns(), html, fn pattern, acc ->
      Regex.replace(pattern, acc, "")
    end)
  end

  defp style_hidden_patterns do
    [
      ~r/<([a-zA-Z][\w:-]*)\b[^>]*\bstyle\s*=\s*(["'])[^"']*\bdisplay\s*:\s*none\b[^"']*\2[^>]*>.*?<\/\1>/isu,
      ~r/<([a-zA-Z][\w:-]*)\b[^>]*\bstyle\s*=\s*(["'])[^"']*\bvisibility\s*:\s*hidden\b[^"']*\2[^>]*>.*?<\/\1>/isu,
      ~r/<([a-zA-Z][\w:-]*)\b[^>]*\bstyle\s*=\s*(["'])[^"']*\bopacity\s*:\s*0(?:\b|[^0-9])[^"']*\2[^>]*>.*?<\/\1>/isu,
      ~r/<([a-zA-Z][\w:-]*)\b[^>]*\bstyle\s*=\s*(["'])[^"']*\bfont-size\s*:\s*0(?:px|em|rem|pt|%)?\b[^"']*\2[^>]*>.*?<\/\1>/isu,
      ~r/<([a-zA-Z][\w:-]*)\b[^>]*\bstyle\s*=\s*(["'])[^"']*\btext-indent\s*:\s*-\d{4,}px\b[^"']*\2[^>]*>.*?<\/\1>/isu,
      ~r/<([a-zA-Z][\w:-]*)\b[^>]*\bstyle\s*=\s*(["'])[^"']*\b(?:left|top)\s*:\s*-\d{4,}px\b[^"']*\2[^>]*>.*?<\/\1>/isu,
      ~r/<([a-zA-Z][\w:-]*)\b[^>]*\bstyle\s*=\s*(["'])[^"']*\btransform\s*:\s*scale\s*\(\s*0\s*\)[^"']*\2[^>]*>.*?<\/\1>/isu,
      ~r/<([a-zA-Z][\w:-]*)\b[^>]*\bstyle\s*=\s*(["'])[^"']*\bclip-path\s*:\s*inset\s*\(\s*(?:0*\.\d+|[1-9]\d*(?:\.\d+)?)%[^"']*\2[^>]*>.*?<\/\1>/isu
    ]
  end
end
