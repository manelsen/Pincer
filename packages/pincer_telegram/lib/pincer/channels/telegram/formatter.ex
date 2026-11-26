defmodule Pincer.Channels.Telegram.Formatter do
  @moduledoc """
  Formatting and HTML translation helpers for Telegram messages.

  Handles:
  - Converting Markdown and safe inline HTML into Telegram-compatible HTML
  - Applying reasoning visibility policy before HTML rendering
  - Truncating oversized HTML payloads for message edits
  - Detecting Telegram entity parse errors for plain-text fallback
  """

  alias Pincer.Channels.Shared.Formatting
  alias Pincer.Channels.Telegram.Renderer

  @default_edit_max_chars 3900
  @truncation_suffix "\n…<i>(truncated)</i>"

  @doc """
  Converts standard Markdown and/or safe HTML into Telegram-compatible HTML.

  Uses a Hybrid Fencing strategy via `Pincer.Channels.Shared.Formatting`:
  1. Protects literal HTML blocks (`<pre>`, `<code>`) and safe inline tags
  2. Parses structural Markdown via `EarmarkParser`
  3. Renders the AST through `Pincer.Channels.Telegram.Renderer`
  4. Unfences the protected HTML
  """
  @spec markdown_to_html(String.t() | nil) :: String.t()
  def markdown_to_html(text) do
    Formatting.markdown_to_html(text,
      render_markdown: fn fenced ->
        case EarmarkParser.as_ast(fenced) do
          {:ok, ast, _warnings} -> Renderer.render(ast)
          {:error, ast, _errors} -> Renderer.render(ast)
        end
      end
    )
  end

  @doc """
  Applies reasoning visibility options and renders `text` to Telegram HTML.
  """
  @spec prepare_html(String.t() | nil, keyword()) :: String.t()
  def prepare_html(text, opts \\ []) when is_list(opts) do
    text
    |> Formatting.format_reasoning(opts)
    |> markdown_to_html()
  end

  @doc """
  Strips HTML formatting back into plain text for fallback delivery.
  """
  @spec html_to_plain_text(String.t() | nil) :: String.t() | nil
  def html_to_plain_text(html), do: Formatting.html_to_plain_text(html)

  @doc """
  Truncates an oversized HTML payload for `edit_message_text` retries.
  """
  @spec truncate_html(String.t(), pos_integer()) :: String.t()
  def truncate_html(html_text, max_chars \\ @default_edit_max_chars)
      when is_binary(html_text) and is_integer(max_chars) and max_chars > 0 do
    prefix =
      html_text
      |> String.graphemes()
      |> Enum.take(max_chars)
      |> IO.iodata_to_binary()

    prefix <> @truncation_suffix
  end

  @doc """
  Returns `true` when a Telegram API error description indicates an HTML entity parsing failure.
  """
  @spec parse_error?(term()) :: boolean()
  def parse_error?(desc) when is_binary(desc) do
    desc == "Bad Request: Can't parse entities" or
      String.contains?(desc, "can't parse entities") or
      String.contains?(desc, "can't find end tag")
  end

  def parse_error?(_), do: false
end
