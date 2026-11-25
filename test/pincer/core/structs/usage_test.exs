defmodule Pincer.Core.Structs.UsageTest do
  use ExUnit.Case, async: true

  alias PincerPorts.Structs.Usage

  describe "normalize/1" do
    test "returns zeroed struct for nil and non-map inputs" do
      assert Usage.normalize(nil) == %Usage{
               prompt_tokens: 0,
               completion_tokens: 0,
               total_tokens: 0
             }

      assert Usage.normalize(:invalid) == %Usage{
               prompt_tokens: 0,
               completion_tokens: 0,
               total_tokens: 0
             }
    end

    test "normalizes string-keyed OpenAI usage maps and computes total when omitted" do
      assert Usage.normalize(%{"prompt_tokens" => 12, "completion_tokens" => 34}) == %Usage{
               prompt_tokens: 12,
               completion_tokens: 34,
               total_tokens: 46
             }
    end

    test "normalizes atom-keyed usage maps and preserves explicit total" do
      assert Usage.normalize(%{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}) ==
               %Usage{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
    end

    test "normalizes Anthropic input_tokens and output_tokens keys" do
      assert Usage.normalize(%{"input_tokens" => 20, "output_tokens" => 8}) == %Usage{
               prompt_tokens: 20,
               completion_tokens: 8,
               total_tokens: 28
             }
    end

    test "preserves total-only payloads" do
      assert Usage.normalize(%{"total_tokens" => 42}) == %Usage{
               prompt_tokens: 0,
               completion_tokens: 0,
               total_tokens: 42
             }
    end

    test "clamps negative values and handles string numbers" do
      assert Usage.normalize(%{"prompt_tokens" => -5, "completion_tokens" => "14"}) == %Usage{
               prompt_tokens: 0,
               completion_tokens: 14,
               total_tokens: 14
             }
    end

    test "re-normalizes an existing Usage struct cleanly" do
      raw = %Usage{prompt_tokens: 3, completion_tokens: 4, total_tokens: 0}

      assert Usage.normalize(raw) == %Usage{
               prompt_tokens: 3,
               completion_tokens: 4,
               total_tokens: 7
             }
    end
  end

  describe "normalize_optional/1" do
    test "keeps nil as nil" do
      assert Usage.normalize_optional(nil) == nil
    end

    test "normalizes maps to Usage struct" do
      assert Usage.normalize_optional(%{"prompt_tokens" => 7, "completion_tokens" => 3}) ==
               %Usage{prompt_tokens: 7, completion_tokens: 3, total_tokens: 10}
    end
  end

  describe "add/2 and to_map/1" do
    test "adds two Usage structs and serializes to string-keyed map" do
      a = Usage.new(prompt_tokens: 10, completion_tokens: 5)
      b = Usage.new(%{"prompt_tokens" => 4, "completion_tokens" => 6})
      sum = Usage.add(a, b)

      assert sum == %Usage{prompt_tokens: 14, completion_tokens: 11, total_tokens: 25}

      assert Usage.to_map(sum) == %{
               "prompt_tokens" => 14,
               "completion_tokens" => 11,
               "total_tokens" => 25
             }
    end
  end
end
