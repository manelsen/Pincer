defmodule Pincer.Core.ConfigProbeTest do
  use ExUnit.Case, async: true

  alias Pincer.Core.ConfigProbe

  defp config do
    %{
      "channels" => %{
        "telegram" => %{
          "enabled" => true,
          "token_env" => "TG_TOKEN",
          "dm_policy" => %{"mode" => "pairing"}
        },
        "discord" => %{"enabled" => "true", "dm_policy" => %{"mode" => "Open"}},
        "slack" => %{"enabled" => true, "token_env" => "SLACK_TOKEN"},
        "whatsapp" => %{"enabled" => false},
        "cli" => %{"enabled" => true}
      }
    }
  end

  describe "channels/1" do
    test "normalises names and keeps config maps" do
      chans = ConfigProbe.channels(%{"channels" => %{"Telegram" => %{"enabled" => true}}})
      assert chans == [{"telegram", %{"enabled" => true}}]
    end

    test "returns [] when the section is missing or malformed" do
      assert ConfigProbe.channels(%{}) == []
      assert ConfigProbe.channels(%{"channels" => "nope"}) == []
      assert ConfigProbe.channels(nil) == []
    end

    test "coerces non-map channel configs to empty maps" do
      assert ConfigProbe.channels(%{"channels" => %{"x" => nil}}) == [{"x", %{}}]
    end
  end

  describe "enabled_channels/1 and enabled_dm_channels/1" do
    test "keeps channels enabled with true or the string \"true\"" do
      names = config() |> ConfigProbe.enabled_channels() |> Enum.map(&elem(&1, 0))
      assert Enum.sort(names) == ["cli", "discord", "slack", "telegram"]
    end

    test "restricts DM channels to telegram, discord and whatsapp" do
      names = config() |> ConfigProbe.enabled_dm_channels() |> Enum.map(&elem(&1, 0))
      assert Enum.sort(names) == ["discord", "telegram"]
    end
  end

  describe "enabled?/1" do
    test "accepts booleans and the string form only" do
      assert ConfigProbe.enabled?(%{"enabled" => true})
      assert ConfigProbe.enabled?(%{"enabled" => "true"})
      refute ConfigProbe.enabled?(%{"enabled" => "yes"})
      refute ConfigProbe.enabled?(%{"enabled" => 1})
      refute ConfigProbe.enabled?(%{})
      refute ConfigProbe.enabled?(nil)
    end
  end

  describe "token_state/2 and token_env/1" do
    test "present when the env var is set" do
      env = fn "TG_TOKEN" -> "secret" end
      assert ConfigProbe.token_state(%{"token_env" => "TG_TOKEN"}, env) == :present
    end

    test "missing_value when the var is unset or blank" do
      assert ConfigProbe.token_state(%{"token_env" => "TG_TOKEN"}, fn _ -> nil end) ==
               :missing_value

      assert ConfigProbe.token_state(%{"token_env" => "TG_TOKEN"}, fn _ -> "  " end) ==
               :missing_value
    end

    test "missing_env_key when the channel declares no token_env" do
      assert ConfigProbe.token_state(%{}, fn _ -> "x" end) == :missing_env_key
      assert ConfigProbe.token_state(%{"token_env" => nil}, fn _ -> "x" end) == :missing_env_key
    end

    test "token_env returns the declared key or nil" do
      assert ConfigProbe.token_env(%{"token_env" => "A"}) == "A"
      assert ConfigProbe.token_env(%{}) == nil
      assert ConfigProbe.token_env(%{"token_env" => 123}) == nil
    end
  end

  describe "dm_mode/1 and dm_mode_value/1" do
    test "reads and normalises the mode from a policy map" do
      assert ConfigProbe.dm_mode(%{"mode" => "pairing"}) == :pairing
      assert ConfigProbe.dm_mode(%{"mode" => " AllowList "}) == :allowlist
      assert ConfigProbe.dm_mode(%{"mode" => "OPEN"}) == :open
    end

    test "distinguishes missing from invalid" do
      assert ConfigProbe.dm_mode(nil) == :missing
      assert ConfigProbe.dm_mode(%{}) == :missing
      assert ConfigProbe.dm_mode(%{"mode" => ""}) == :missing
      assert ConfigProbe.dm_mode(%{"mode" => "nonsense"}) == :invalid
      assert ConfigProbe.dm_mode("not-a-map") == :invalid
    end
  end

  describe "channel classification" do
    test "token_required_channel? lists telegram, discord and slack only" do
      assert ConfigProbe.token_required_channel?("telegram")
      assert ConfigProbe.token_required_channel?("discord")
      assert ConfigProbe.token_required_channel?("slack")
      refute ConfigProbe.token_required_channel?("webhook")
      refute ConfigProbe.token_required_channel?("cli")
    end

    test "dm_capable_channel? lists telegram, discord and whatsapp" do
      assert ConfigProbe.dm_capable_channel?("whatsapp")
      refute ConfigProbe.dm_capable_channel?("slack")
    end
  end

  describe "normalize_channel_name/1 and normalize_map/1" do
    test "lowercases and trims" do
      assert ConfigProbe.normalize_channel_name("  Telegram ") == "telegram"
      assert ConfigProbe.normalize_channel_name(:discord) == "discord"
    end

    test "normalize_map passes maps through and empties everything else" do
      assert ConfigProbe.normalize_map(%{"a" => 1}) == %{"a" => 1}
      assert ConfigProbe.normalize_map(nil) == %{}
      assert ConfigProbe.normalize_map([1]) == %{}
    end
  end
end
