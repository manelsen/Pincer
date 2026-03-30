defmodule Pincer.Channels.Feishu.CardsTest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.Feishu.Cards

  describe "create_card/1" do
    test "returns a card map with a single div element containing lark_md content" do
      card = Cards.create_card("hello")

      assert %{"elements" => elements} = card
      assert length(elements) == 1

      assert [%{"tag" => "div", "text" => %{"tag" => "lark_md", "content" => "hello"}}] = elements
    end
  end

  describe "update_card_content/2" do
    test "replaces content of the first div element" do
      card = Cards.create_card("hello")
      updated = Cards.update_card_content(card, "updated")

      assert %{"elements" => [%{"text" => %{"content" => "updated"}}]} = updated
    end

    test "only updates the first div when card has multiple elements" do
      card = %{
        "elements" => [
          %{"tag" => "div", "text" => %{"tag" => "lark_md", "content" => "first"}},
          %{"tag" => "div", "text" => %{"tag" => "lark_md", "content" => "second"}},
          %{"tag" => "div", "text" => %{"tag" => "lark_md", "content" => "third"}}
        ]
      }

      updated = Cards.update_card_content(card, "replaced")

      assert %{"elements" => elements} = updated
      assert length(elements) == 3

      [first, second, third] = elements

      assert first["text"]["content"] == "replaced"
      assert second["text"]["content"] == "second"
      assert third["text"]["content"] == "third"
    end

    test "preserves non-div elements unchanged" do
      card = %{
        "elements" => [
          %{"tag" => "div", "text" => %{"tag" => "lark_md", "content" => "old"}},
          %{"tag" => "action", "actions" => []}
        ]
      }

      updated = Cards.update_card_content(card, "new")

      assert %{"elements" => [div_elem, action_elem]} = updated
      assert div_elem["text"]["content"] == "new"
      assert action_elem == %{"tag" => "action", "actions" => []}
    end
  end

  describe "build_markdown_element/1" do
    test "returns a div element map with lark_md tag and given text" do
      element = Cards.build_markdown_element("test")

      assert element == %{
               "tag" => "div",
               "text" => %{"tag" => "lark_md", "content" => "test"}
             }
    end
  end
end
