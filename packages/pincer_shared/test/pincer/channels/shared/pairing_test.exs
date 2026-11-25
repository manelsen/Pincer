defmodule Pincer.Channels.Shared.PairingTest do
  use ExUnit.Case, async: true

  alias Pincer.Channels.Shared.Pairing

  defmodule PolicyStub do
    def allow?(:dm_access, %{sender_id: "allowed"}), do: {:allow, %{}}

    def allow?(:dm_access, %{sender_id: "blocked"}),
      do: {:deny, %{user_message: "DM blocked by policy"}}

    def approve_code(:telegram, "u1", "123456"), do: :ok
    def approve_code(:discord, "u2", "654321"), do: :ok
    def approve_code(_ch, _sender, "pending"), do: {:error, :not_pending}
    def approve_code(_ch, _sender, "expired"), do: {:error, :expired}
    def approve_code(_ch, _sender, "bad"), do: {:error, :invalid_code}
    def approve_code(_ch, _sender, "locked"), do: {:error, :attempts_exceeded}

    def bound_agent_id(:telegram, "u1"), do: "agent_alpha"
    def bound_agent_id(_, _), do: nil
  end

  describe "command parsing" do
    test "pair_command?/1 and extract_code/1 normalize whitespace and case" do
      assert Pairing.pair_command?("/pair 123456")
      assert Pairing.pair_command?("  /PAIR  ")
      refute Pairing.pair_command?("/help")

      assert Pairing.extract_code("/pair 123456") == "123456"
      assert Pairing.extract_code("/pair") == ""
      assert Pairing.extract_code("  654321 ") == "654321"
      assert Pairing.extract_code(nil) == ""
    end
  end

  describe "authorize_dm/4" do
    test "allows non-DM contexts without calling policy" do
      assert :allow ==
               Pairing.authorize_dm(:telegram, "blocked", %{},
                 is_dm: false,
                 policy_module: PolicyStub
               )
    end

    test "delegates DM checks to policy_module and maps allow/deny" do
      assert :allow ==
               Pairing.authorize_dm(:telegram, "allowed", %{}, policy_module: PolicyStub)

      assert {:deny, "DM blocked by policy"} ==
               Pairing.authorize_dm(:telegram, "blocked", %{}, policy_module: PolicyStub)
    end
  end

  describe "approve/4" do
    test "rejects non-DM requests with configurable message" do
      assert {:error, :dm_only, "Pairing so pode ser concluido em DM privada."} ==
               Pairing.approve(:telegram, "u1", "123456", is_dm: false, policy_module: PolicyStub)

      assert {:error, :dm_only, "Pairing only works in direct messages."} ==
               Pairing.approve(:whatsapp, "u1", "123456",
                 is_dm: false,
                 dm_only_message: "Pairing only works in direct messages.",
                 policy_module: PolicyStub
               )
    end

    test "requires a non-empty pairing code" do
      assert {:error, :missing_code,
              "Uso: /pair <codigo>. Solicite o codigo de pairing ao operador."} ==
               Pairing.approve(:discord, "u2", "  ", policy_module: PolicyStub)
    end

    test "approves valid code, invokes on_approved, and formats bound agent when requested" do
      parent = self()

      assert {:ok,
              "Pairing concluido com sucesso. Esta DM agora aponta para o agente <code>agent_alpha</code>."} ==
               Pairing.approve(:telegram, "u1", "/pair 123456",
                 policy_module: PolicyStub,
                 include_bound_agent: true,
                 format_bound_agent: &"Esta DM agora aponta para o agente <code>#{&1}</code>.",
                 on_approved: fn -> send(parent, :approved_hook_called) end
               )

      assert_received :approved_hook_called

      assert {:ok, "Pairing concluido com sucesso. Agora sua DM esta autorizada."} ==
               Pairing.approve(:discord, "u2", "654321", policy_module: PolicyStub)
    end

    test "maps policy errors to canonical guidance messages" do
      assert {:error, :not_pending, msg} =
               Pairing.approve(:discord, "u2", "pending", policy_module: PolicyStub)

      assert msg =~ "Nenhum pairing pendente"

      assert {:error, :expired, msg} =
               Pairing.approve(:discord, "u2", "expired", policy_module: PolicyStub)

      assert msg =~ "expirado"

      assert {:error, :invalid_code, msg} =
               Pairing.approve(:discord, "u2", "bad", policy_module: PolicyStub)

      assert msg =~ "invalido"

      assert {:error, :attempts_exceeded, msg} =
               Pairing.approve(:discord, "u2", "locked", policy_module: PolicyStub)

      assert msg =~ "Tentativas excedidas"
    end
  end
end
