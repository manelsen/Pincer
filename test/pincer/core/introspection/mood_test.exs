defmodule Pincer.Core.Introspection.MoodTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Introspection.Mood

  describe "from_outcome/3" do
    test "success increases valence" do
      {v, _a} = Mood.from_outcome(:success, 0.0, 0.0)
      assert v > 0.0
    end

    test "success increases arousal slightly" do
      {_v, a} = Mood.from_outcome(:success, 0.0, 0.0)
      assert a > 0.0
    end

    test "failure decreases valence" do
      {v, _a} = Mood.from_outcome(:failure, 0.0, 0.0)
      assert v < 0.0
    end

    test "failure increases arousal (frustration)" do
      {_v, a} = Mood.from_outcome(:failure, 0.0, 0.0)
      assert a > 0.0
    end

    test "clamps result within bounds" do
      {v, a} = Mood.from_outcome(:success, 0.98, 0.99)
      assert v <= 1.0
      assert a <= 1.0

      {v2, a2} = Mood.from_outcome(:failure, -0.95, 0.0)
      assert v2 >= -1.0
      assert a2 >= 0.0
    end
  end

  describe "decay/3" do
    test "moves valence toward zero" do
      {v, _a} = Mood.decay(0.5, 0.5)
      assert v < 0.5
      assert v > 0.0
    end

    test "moves arousal toward zero" do
      {_v, a} = Mood.decay(0.5, 0.5)
      assert a < 0.5
      assert a > 0.0
    end

    test "negative valence also moves toward zero" do
      {v, _a} = Mood.decay(-0.5, 0.5)
      assert v > -0.5
      assert v < 0.0
    end

    test "zero stays zero" do
      assert Mood.decay(0.0, 0.0) == {0.0, 0.0}
    end

    test "custom rate is respected" do
      {v1, _} = Mood.decay(1.0, 0.0, 0.5)
      assert_in_delta v1, 0.5, 0.001

      {v2, _} = Mood.decay(1.0, 0.0, 0.1)
      assert_in_delta v2, 0.9, 0.001
    end
  end

  describe "blend_llm/5" do
    test "blends current with LLM suggestion" do
      {v, a} = Mood.blend_llm(0.0, 0.0, 1.0, 1.0, 0.3)
      assert_in_delta v, 0.3, 0.001
      assert_in_delta a, 0.3, 0.001
    end

    test "weight 0.0 keeps current unchanged" do
      {v, a} = Mood.blend_llm(0.5, 0.5, -1.0, 1.0, 0.0)
      assert_in_delta v, 0.5, 0.001
      assert_in_delta a, 0.5, 0.001
    end

    test "weight 1.0 fully adopts LLM values" do
      {v, a} = Mood.blend_llm(0.5, 0.5, -0.8, 0.2, 1.0)
      assert_in_delta v, -0.8, 0.001
      assert_in_delta a, 0.2, 0.001
    end

    test "default weight is 0.3" do
      {v, _a} = Mood.blend_llm(0.0, 0.0, 1.0, 0.0)
      assert_in_delta v, 0.3, 0.001
    end
  end

  describe "clamp/1" do
    test "clamps valence to [-1.0, 1.0]" do
      assert {1.0, _} = Mood.clamp({2.0, 0.5})
      assert {-1.0, _} = Mood.clamp({-3.0, 0.5})
    end

    test "clamps arousal to [0.0, 1.0]" do
      {_, a_high} = Mood.clamp({0.0, 5.0})
      assert a_high == 1.0

      {_, a_low} = Mood.clamp({0.0, -1.0})
      assert a_low == +0.0
    end

    test "values within bounds pass through" do
      assert {0.5, 0.3} = Mood.clamp({0.5, 0.3})
    end
  end

  describe "label/2" do
    test "neutral when both near zero" do
      assert Mood.label(0.0, 0.0) == "neutral"
      assert Mood.label(0.1, 0.1) == "neutral"
    end

    test "energized with high positive valence and high arousal" do
      assert Mood.label(0.6, 0.8) == "energized"
    end

    test "content with high positive valence and low arousal" do
      assert Mood.label(0.5, 0.1) == "content"
    end

    test "frustrated with negative valence and high arousal" do
      assert Mood.label(-0.5, 0.8) == "frustrated"
    end

    test "subdued with negative valence and low arousal" do
      assert Mood.label(-0.5, 0.1) == "subdued"
    end
  end
end
