defmodule Pincer.Channels.Telegram.Renderer do
  @moduledoc """
  Professional AST-based renderer for Telegram HTML.
  Converts Earmark AST into Telegram-safe HTML tags.
  """

  @doc """
  Renders Earmark AST into Telegram HTML.
  """
  def render(ast) when is_list(ast) do
    ast
    |> Enum.map(&render_node/1)
    |> Enum.join("")
    |> String.trim()
  end

  # Text Nodes
  defp render_node(text) when is_binary(text) do
    escape_html(text)
  end

  # Paragraphs: Render content and add double newline (if not at end)
  defp render_node({"p", _attrs, children, _meta}) do
    render(children) <> "\n\n"
  end

  # Headers (h1-h6): Map to Bold
  defp render_node({tag, _attrs, children, _meta}) when tag in ~w(h1 h2 h3 h4 h5 h6) do
    "<b>" <> render(children) <> "</b>\n\n"
  end

  # Bold / Strong
  defp render_node({tag, _attrs, children, _meta}) when tag in ~w(b strong) do
    "<b>" <> render(children) <> "</b>"
  end

  # Italic / Em
  defp render_node({tag, _attrs, children, _meta}) when tag in ~w(i em) do
    "<i>" <> render(children) <> "</i>"
  end

  # Underline
  defp render_node({tag, _attrs, children, _meta}) when tag in ~w(u ins) do
    "<u>" <> render(children) <> "</u>"
  end

  # Strikethrough
  defp render_node({tag, _attrs, children, _meta}) when tag in ~w(s strike del) do
    "<s>" <> render(children) <> "</s>"
  end

  # Blockquote
  defp render_node({"blockquote", _attrs, children, _meta}) do
    "\n<blockquote>" <> String.trim(render(children)) <> "</blockquote>\n\n"
  end

  # Code Blocks (<pre>)
  defp render_node({"pre", _attrs, [{"code", [{"class", class}], [code], _m1}], _m2}) do
    lang = class |> String.replace("language-", "")
    "<pre><code class=\"language-#{lang}\">" <> escape_html(code) <> "</code></pre>\n\n"
  end

  defp render_node({"pre", _attrs, [{"code", _attrs_code, [code], _m3}], _m4}) do
    "<pre>" <> escape_html(code) <> "</pre>\n\n"
  end

  # Fallback for complex pre blocks (often from Earmark fallbacks)
  defp render_node({"pre", _attrs, children, _m5}) when is_list(children) do
    "<pre>" <> render(children) <> "</pre>\n\n"
  end

  # Inline Code
  defp render_node({"code", _attrs, [code], _m6}) when is_binary(code) do
    "<code>" <> escape_html(code) <> "</code>"
  end

  defp render_node({"code", _attrs, children, _m7}) when is_list(children) do
    "<code>" <> render(children) <> "</code>"
  end

  # Links
  defp render_node({"a", attrs, children, _m8}) do
    case List.keyfind(attrs, "href", 0) do
      {_, href} -> "<a href=\"#{href}\">" <> render(children) <> "</a>"
      nil -> render(children)
    end
  end

  # Horizontal Rule
  defp render_node({"hr", _attrs, _children, _m9}) do
    "\n<b>───────────────</b>\n\n"
  end

  # Lists (ul/ol)
  defp render_node({"ul", _attrs, children, _m10}) do
    "\n" <> render_list(children, :unordered) <> "\n"
  end

  defp render_node({"ol", _attrs, children, _m11}) do
    "\n" <> render_list(children, :ordered) <> "\n"
  end

  # List Items
  defp render_node({"li", _attrs, children, _m12}) do
    "• " <> String.trim(render(children)) <> "\n"
  end

  # Fallback: Just render children or text
  defp render_node({_tag, _attrs, children, _m13}) when is_list(children) do
    render(children)
  end

  defp render_node(_other), do: ""

  # --- Helpers ---

  defp render_list(items, type) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn
      {{"li", _attrs, children, _m_inner}, index} ->
        prefix = if type == :ordered, do: "#{index}. ", else: "• "
        prefix <> String.trim(render(children)) <> "\n"

      {other, _} ->
        render([other])
    end)
    |> Enum.join("")
  end

  defp escape_html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
