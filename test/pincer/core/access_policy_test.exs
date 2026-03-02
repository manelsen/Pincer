defmodule Pincer.Core.AccessPolicyTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.AccessPolicy
  alias Pincer.Core.Pairing

  setup do
    Pairing.reset()

    on_exit(fn ->
      Pairing.reset()
    end)

    :ok
  end

  describe "authorize_dm/3" do
    test "defaults to open mode when config is missing" do
      assert {:allow, %{mode: :open}} = AccessPolicy.authorize_dm(:telegram, 123, %{})
    end

    test "allows in open mode" do
      config = %{"dm_policy" => %{"mode" => "open"}}
      assert {:allow, %{mode: :open}} = AccessPolicy.authorize_dm(:discord, "abc", config)
    end

    test "allows allowlisted sender ids with exact match" do
      config = %{"dm_policy" => %{"mode" => "allowlist", "allow_from" => ["123", "777"]}}
      assert {:allow, %{mode: :allowlist}} = AccessPolicy.authorize_dm(:telegram, 123, config)
    end

    test "allows allowlisted sender ids with wildcard match" do
      config = %{"dm_policy" => %{"mode" => "allowlist", "allow_from" => ["77*"]}}
      assert {:allow, %{mode: :allowlist}} = AccessPolicy.authorize_dm(:telegram, 7788, config)
    end

    test "allows all in allowlist mode when wildcard star is present" do
      config = %{"dm_policy" => %{"mode" => "allowlist", "allow_from" => ["*"]}}
      assert {:allow, %{mode: :allowlist}} = AccessPolicy.authorize_dm(:discord, "anyone", config)
    end

    test "denies non-allowlisted sender ids in allowlist mode" do
      config = %{"dm_policy" => %{"mode" => "allowlist", "allow_from" => ["123"]}}

      assert {:deny, %{mode: :allowlist, reason: :not_allowlisted, user_message: msg}} =
               AccessPolicy.authorize_dm(:telegram, 999, config)

      assert msg =~ "nao esta autorizado"
    end

    test "denies in disabled mode" do
      config = %{"dm_policy" => %{"mode" => "disabled"}}

      assert {:deny, %{mode: :disabled, reason: :dm_disabled, user_message: msg}} =
               AccessPolicy.authorize_dm(:telegram, 1, config)

      assert msg =~ "desativadas"
    end

    test "denies in pairing mode and returns pairing code for unpaired sender" do
      config = %{"dm_policy" => %{"mode" => "pairing"}}

      assert {:deny, %{mode: :pairing, reason: :pairing_required, user_message: msg}} =
               AccessPolicy.authorize_dm(:discord, "u-1", config)

      assert msg =~ "pairing"
      assert msg =~ "/pair <codigo>"
      refute msg =~ ~r/\b\d{6}\b/
    end

    test "allows in pairing mode after valid code approval" do
      config = %{"dm_policy" => %{"mode" => "pairing"}}

      assert {:deny, %{user_message: msg}} =
               AccessPolicy.authorize_dm(:telegram, 123, config)

      refute msg =~ ~r/\b\d{6}\b/

      assert {:ok, %{code: code}} = Pairing.issue_code(:telegram, "123")

      assert :ok == Pairing.approve_code(:telegram, "123", code)

      assert {:allow, %{mode: :pairing}} =
               AccessPolicy.authorize_dm(:telegram, 123, config)
    end

    test "falls back to open mode on invalid policy mode" do
      config = %{"dm_policy" => %{"mode" => "not-a-real-mode"}}
      assert {:allow, %{mode: :open}} = AccessPolicy.authorize_dm(:telegram, 10, config)
    end
  end
end
