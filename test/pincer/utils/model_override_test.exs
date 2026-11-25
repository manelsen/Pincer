defmodule Pincer.Utils.ModelOverrideTest do
  use ExUnit.Case, async: true

  alias Pincer.Utils.ModelOverride

  test "normalizes provider and model keys and keeps optional thinking" do
    assert ModelOverride.normalize(%{"provider" => "a", :model => "b", "thinking_level" => "low"}) ==
             %{provider: "a", model: "b", thinking_level: "low"}
  end

  test "rejects absent or empty identifiers" do
    assert ModelOverride.normalize(nil) == nil
    assert ModelOverride.normalize(%{provider: "a", model: ""}) == nil
  end
end
