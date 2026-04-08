defmodule Pincer.Channels.Feishu.Cards do
  @moduledoc """
  Pure-data builder for Feishu CardKit v2 interactive card payloads.

  Produces maps suitable for JSON encoding and sending via the Feishu
  card update API. No side effects, no GenServer — just map construction.
  """

  @doc """
  Creates a new card containing a single markdown element.

  ## Examples

      iex> Cards.create_card("hello")
      %{"elements" => [%{"tag" => "div", "text" => %{"tag" => "lark_md", "content" => "hello"}}]}
  """
  @spec create_card(String.t()) :: map()
  def create_card(initial_content) do
    %{"elements" => [build_markdown_element(initial_content)]}
  end

  @doc """
  Returns a new card with the first `"div"` element's text content replaced.

  Non-div elements and subsequent div elements are left unchanged.

  ## Examples

      iex> card = Cards.create_card("old")
      iex> Cards.update_card_content(card, "new")
      %{"elements" => [%{"tag" => "div", "text" => %{"tag" => "lark_md", "content" => "new"}}]}
  """
  @spec update_card_content(map(), String.t()) :: map()
  def update_card_content(%{"elements" => elements} = _card, new_content) do
    {updated_elements, _replaced?} =
      Enum.map_reduce(elements, false, fn
        %{"tag" => "div", "text" => text} = elem, false ->
          {%{elem | "text" => %{text | "content" => new_content}}, true}

        elem, replaced? ->
          {elem, replaced?}
      end)

    %{"elements" => updated_elements}
  end

  @doc """
  Builds a single Feishu markdown element map.

  ## Examples

      iex> Cards.build_markdown_element("hi")
      %{"tag" => "div", "text" => %{"tag" => "lark_md", "content" => "hi"}}
  """
  @spec build_markdown_element(String.t()) :: map()
  def build_markdown_element(text) do
    %{"tag" => "div", "text" => %{"tag" => "lark_md", "content" => text}}
  end
end
