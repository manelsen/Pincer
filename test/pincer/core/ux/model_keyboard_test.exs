defmodule Pincer.Core.UX.ModelKeyboardTest do
  use ExUnit.Case, async: true
  alias Pincer.Core.UX.ModelKeyboard

  describe "paginate/2" do
    test "empty list" do
      assert ModelKeyboard.paginate([], 1) == {[], 1}
    end

    test "first page with 10 items" do
      items = Enum.map(1..10, &"m#{&1}")
      {page_items, total_pages} = ModelKeyboard.paginate(items, 1)
      assert length(page_items) == 8
      assert total_pages == 2
    end

    test "second page with 10 items" do
      items = Enum.map(1..10, &"m#{&1}")
      {page_items, total_pages} = ModelKeyboard.paginate(items, 2)
      assert length(page_items) == 2
      assert total_pages == 2
    end

    test "page out of bounds clamps to valid range" do
      {page_items, total_pages} = ModelKeyboard.paginate(["a", "b"], 99)
      assert page_items == ["a", "b"]
      assert total_pages == 1
    end
  end
end
