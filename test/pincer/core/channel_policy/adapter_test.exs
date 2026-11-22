defmodule Pincer.Core.ChannelPolicy.AdapterTest do
  @moduledoc """
  Verifies the `Pincer.Ports.ChannelPolicy` port contract.

  Runs synchronously because the adapter touches global ETS tables (pairing)
  and the dispatch test swaps the application env.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Pincer.Core.ChannelPolicy.Adapter
  alias Pincer.Core.Pairing

  @unpaired_sender "port-test-unpaired-#{System.unique_integer([:positive])}"

  defmodule Stub do
    @behaviour Pincer.Ports.ChannelPolicy

    def allow?(kind, attrs), do: {:allow?, kind, attrs}
    def classify(kind, attrs), do: {:classify, kind, attrs}

    def approve_code(channel, sender_id, code, opts),
      do: {:approve_code, channel, sender_id, code, opts}

    def bound_agent_id(channel, sender_id), do: {:bound_agent_id, channel, sender_id}
    def provider_selector_id(channel, id), do: {:provider_selector_id, channel, id}

    def model_selector_id(channel, provider_id, model),
      do: {:model_selector_id, channel, provider_id, model}

    def back_to_providers_id(channel), do: {:back_to_providers_id, channel}
    def menu_id(channel), do: {:menu_id, channel}
    def approval_button_spec, do: :approval_button_spec
    def parse(channel, payload), do: {:parse, channel, payload}
    def error_message(channel, text), do: {:error_message, channel, text}
    def approval_message(channel, command), do: {:approval_message, channel, command}
    def status_kind(text), do: {:status_kind, text}
    def emit_error(reason, meta), do: {:emit_error, reason, meta}
  end

  setup do
    Pairing.reset()
    on_exit(fn -> Pairing.reset() end)
    :ok
  end

  test "implements the ChannelPolicy behaviour and its callbacks" do
    behaviours =
      Adapter.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert Pincer.Ports.ChannelPolicy in behaviours

    for {fun, arity} <- Pincer.Ports.ChannelPolicy.behaviour_info(:callbacks) do
      assert function_exported?(Adapter, fun, arity),
             "Adapter does not implement #{fun}/#{arity}"
    end
  end

  test "the test double covers every port callback" do
    for {fun, arity} <- Pincer.Ports.ChannelPolicy.behaviour_info(:callbacks) do
      assert function_exported?(Stub, fun, arity),
             "Stub does not implement #{fun}/#{arity} - update it with the port"
    end
  end

  describe "pure decisions" do
    test "approval_button_spec/0 returns label/payload pairs the parser accepts" do
      spec = Adapter.approval_button_spec()

      assert spec == [
               {"✅ Aprovo", "appr:y"},
               {"🔓 Tudo 10min", "appr:a"},
               {"❌ Rejeito", "appr:n"}
             ]

      for {label, payload} <- spec do
        assert is_binary(label) and label != ""
        assert {:ok, _} = Adapter.parse(:telegram, payload)
      end
    end

    test "parse/2 recognises approval payloads and rejects junk" do
      assert Adapter.parse(:telegram, "appr:y") == {:ok, {:approval, :approved}}
      assert Adapter.parse(:telegram, "appr:n") == {:ok, {:approval, :rejected}}
      assert Adapter.parse(:telegram, "appr:a") == {:ok, {:approval, :approve_all}}
      assert Adapter.parse(:discord, "appr:y") == {:ok, {:approval, :approved}}
      assert Adapter.parse(:telegram, "nonsense") == {:error, :invalid_payload}
      assert Adapter.parse(:telegram, String.duplicate("x", 65)) == {:error, :payload_too_large}
      assert Adapter.parse(:pager, "appr:y") == {:error, :invalid_channel}
    end

    test "error_message/2 formats per channel and falls back to a generic form" do
      assert Adapter.error_message(:telegram, "boom") == "❌ <b>Agent Error</b>: boom"
      assert Adapter.error_message(:discord, "boom") == "❌ **Agent Error**: boom"
      assert Adapter.error_message(:whatsapp, "boom") == "Agent error: boom"
      assert Adapter.error_message(:pager, "boom") == "Agent error: boom"
    end

    test "status_kind/1 distinguishes sub-agent status lines" do
      assert Adapter.status_kind("idle") == :plain
      assert Adapter.status_kind("Sub-Agent: working") == :subagent
    end
  end

  describe "stateful decisions for an unknown sender" do
    test "approve_code/4 reports :not_pending when there is no pending request" do
      capture_log(fn ->
        assert Adapter.approve_code(:telegram, @unpaired_sender, "123456", []) ==
                 {:error, :not_pending}

        assert Adapter.approve_code(:discord, @unpaired_sender, "123456", []) ==
                 {:error, :not_pending}
      end)
    end

    test "bound_agent_id/2 returns nil for an unpaired sender" do
      assert Adapter.bound_agent_id(:telegram, @unpaired_sender) == nil
      assert Adapter.bound_agent_id(:discord, @unpaired_sender) == nil
    end
  end

  describe "port dispatch" do
    setup do
      previous = Application.get_env(:pincer, :channel_policy_adapter)
      Application.put_env(:pincer, :channel_policy_adapter, Stub)
      on_exit(fn -> restore(previous) end)
      :ok
    end

    test "routes every operation through the configured adapter" do
      alias Pincer.Ports.ChannelPolicy

      assert ChannelPolicy.allow?(:dm_access, %{sender_id: "1"}) ==
               {:allow?, :dm_access, %{sender_id: "1"}}

      assert ChannelPolicy.classify(:dm_access, %{}) == {:classify, :dm_access, %{}}

      assert ChannelPolicy.approve_code(:telegram, "1", "code") ==
               {:approve_code, :telegram, "1", "code", []}

      assert ChannelPolicy.approve_code(:telegram, "1", "code", max_attempts: 2) ==
               {:approve_code, :telegram, "1", "code", [max_attempts: 2]}

      assert ChannelPolicy.bound_agent_id(:telegram, "1") == {:bound_agent_id, :telegram, "1"}

      assert ChannelPolicy.provider_selector_id(:telegram, "p") ==
               {:provider_selector_id, :telegram, "p"}

      assert ChannelPolicy.model_selector_id(:telegram, "p", "m") ==
               {:model_selector_id, :telegram, "p", "m"}

      assert ChannelPolicy.back_to_providers_id(:discord) == {:back_to_providers_id, :discord}
      assert ChannelPolicy.menu_id(:discord) == {:menu_id, :discord}
      assert ChannelPolicy.approval_button_spec() == :approval_button_spec
      assert ChannelPolicy.parse(:telegram, "appr:y") == {:parse, :telegram, "appr:y"}
      assert ChannelPolicy.error_message(:telegram, "x") == {:error_message, :telegram, "x"}

      assert ChannelPolicy.approval_message(:telegram, "ls") ==
               {:approval_message, :telegram, "ls"}

      assert ChannelPolicy.status_kind("idle") == {:status_kind, "idle"}
      assert ChannelPolicy.emit_error(:reason) == {:emit_error, :reason, %{}}

      assert ChannelPolicy.emit_error(:reason, %{channel: :telegram}) ==
               {:emit_error, :reason, %{channel: :telegram}}
    end
  end

  defp restore(nil), do: Application.delete_env(:pincer, :channel_policy_adapter)
  defp restore(value), do: Application.put_env(:pincer, :channel_policy_adapter, value)
end
