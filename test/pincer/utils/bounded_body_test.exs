defmodule Pincer.Utils.BoundedBodyTest do
  use ExUnit.Case, async: true

  alias Pincer.Utils.BoundedBody

  test "accumulates chunks below the cap and continues" do
    callback = BoundedBody.callback(5)
    response = %Req.Response{body: ""}

    assert {:cont, {nil, response}} = callback.({:data, "abc"}, {nil, response})
    assert response.body == "abc"
  end

  test "halts as soon as the cap is exceeded" do
    callback = BoundedBody.callback(4)
    response = %Req.Response{body: ""}

    assert {:cont, {nil, response}} = callback.({:data, "abc"}, {nil, response})
    assert {:halt, {nil, response}} = callback.({:data, "de"}, {nil, response})
    assert response.body == "abcde"
  end
end
