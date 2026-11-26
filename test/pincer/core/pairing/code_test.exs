defmodule Pincer.Core.Pairing.CodeTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.Pairing.Code

  describe "normalize_code/1 and hash_code/1" do
    test "normalizes whitespace and case before hashing" do
      assert Code.normalize_code("  ab12cd ") == "AB12CD"
      assert Code.normalize_code(123_456) == "123456"

      hash_a = Code.hash_code("  pair_abc ")
      hash_b = Code.hash_code("PAIR_ABC")

      assert is_binary(hash_a)
      assert byte_size(hash_a) == 32
      assert hash_a == hash_b
    end
  end

  describe "verify?/2" do
    test "verifies matching codes case-insensitively and rejects invalid or malformed inputs" do
      expected_hash = Code.hash_code("ANNIE42")

      assert Code.verify?(expected_hash, "annie42")
      assert Code.verify?(expected_hash, "  ANNIE42 ")
      refute Code.verify?(expected_hash, "WRONG42")
      refute Code.verify?(<<1, 2, 3>>, "ANNIE42")
      refute Code.verify?(nil, "ANNIE42")
    end
  end

  describe "code generation" do
    test "generate_code/1 produces a 6-digit numeric string by default" do
      code = Code.generate_code()
      assert code =~ ~r/^\d{6}$/
    end

    test "generate_invite_code/1 produces an uppercase PAIR_ token by default" do
      code = Code.generate_invite_code()
      assert code =~ ~r/^PAIR_[A-Z2-7]{8}$/
    end

    test "supports custom code_generator and falls back on invalid generator output" do
      assert Code.generate_code(code_generator: fn -> "  abc123 " end) == "ABC123"
      assert Code.generate_code(code_generator: fn -> 987_654 end) == "987654"
      assert Code.generate_code(code_generator: fn -> "" end) =~ ~r/^\d{6}$/

      assert Code.generate_invite_code(code_generator: fn -> "custom_1" end) == "CUSTOM_1"
      assert Code.generate_invite_code(code_generator: fn -> :invalid end) =~ ~r/^PAIR_/
    end
  end

  describe "channel, sender, and key normalization" do
    test "normalizes channel, sender, and composite keys" do
      assert Code.normalize_channel(:Telegram) == "telegram"
      assert Code.normalize_channel("  DiScOrD ") == "discord"
      assert Code.normalize_sender(12345) == "12345"
      assert Code.normalize_sender("  user-1 ") == "user-1"
      assert Code.key(:TELEGRAM, " 42 ") == {"telegram", "42"}

      {channel, hash} = Code.invite_key(:telegram, " annie42 ")
      assert channel == "telegram"
      assert hash == Code.hash_code("ANNIE42")
    end
  end

  describe "agent_id normalization" do
    test "normalize_explicit_agent_id/2 validates and trims explicit ids" do
      assert {:ok, "annie"} = Code.normalize_explicit_agent_id("  annie ")
      assert {:ok, nil} = Code.normalize_explicit_agent_id(nil, allow_nil?: true)
      assert {:ok, nil} = Code.normalize_explicit_agent_id("   ", allow_nil?: true)

      assert {:error, {:invalid_agent_id, msg_empty}} =
               Code.normalize_explicit_agent_id("   ", allow_nil?: false)

      assert msg_empty =~ "cannot be empty"

      assert {:error, {:invalid_agent_id, msg_bad}} =
               Code.normalize_explicit_agent_id("../oops", allow_nil?: false)

      assert msg_bad =~ "agent_id must match"
    end

    test "normalize_stored_agent_id/1 returns nil for malformed ids and normalized id otherwise" do
      assert Code.normalize_stored_agent_id("  agent_1 ") == "agent_1"
      assert Code.normalize_stored_agent_id(nil) == nil
      assert Code.normalize_stored_agent_id("  ") == nil
      assert Code.normalize_stored_agent_id("../oops") == nil
    end
  end

  describe "timing and option helpers" do
    test "extracts ttl_ms, max_attempts, now_ms, and checks expiration" do
      assert Code.ttl_ms([]) == 300_000
      assert Code.ttl_ms(ttl_ms: 5_000) == 5_000
      assert Code.ttl_ms(ttl_ms: -1) == 300_000

      assert Code.max_attempts([]) == 5
      assert Code.max_attempts(max_attempts: 3) == 3
      assert Code.max_attempts(max_attempts: 0) == 5

      assert Code.now_ms(now_ms: 1_234) == 1_234
      assert is_integer(Code.now_ms([]))

      assert Code.expired?(%{expires_at_ms: 100}, 100)
      assert Code.expired?(%{expires_at_ms: 100}, 101)
      refute Code.expired?(%{expires_at_ms: 100}, 99)
    end
  end
end
