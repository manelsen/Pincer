defmodule Pincer.Utils.ValueTest do
  use ExUnit.Case, async: true

  alias Pincer.Utils.Value

  test "fetch/3 reads atom or string keys from maps" do
    data = %{"fallback" => 1, durations_ms: %{http_429: 100}}

    assert Value.fetch(data, :durations_ms, %{}) == %{http_429: 100}
    assert Value.fetch(data, :fallback, 0) == 1
    assert Value.fetch(data, :missing, 9) == 9
  end

  test "fetch/3 reads keyword lists and tuple lists" do
    assert Value.fetch([durations_ms: %{http_5xx: 50}], :durations_ms, %{}) == %{http_5xx: 50}

    tuple_list = [{"durations_ms", %{http_429: 42}}, {:other, :ok}]
    assert Value.fetch(tuple_list, :durations_ms, %{}) == %{http_429: 42}
    assert Value.fetch(tuple_list, :other, :missing) == :ok
  end

  test "trim_to_nil/1 and trim_string/1 normalize string-like values" do
    assert Value.trim_to_nil("  abc ") == "abc"
    assert Value.trim_to_nil("   ") == nil
    assert Value.trim_to_nil(nil) == nil

    assert Value.trim_string("  abc ") == "abc"
    assert Value.trim_string(nil) == nil
  end
end
