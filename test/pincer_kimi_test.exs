defmodule PincerTest do
  use ExUnit.Case
  doctest Pincer

  test "greets the world" do
    assert Pincer.hello() == :world
  end
end
