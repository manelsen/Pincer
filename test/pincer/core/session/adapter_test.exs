defmodule Pincer.Core.Session.AdapterTest do
  use ExUnit.Case, async: false

  alias Pincer.Core.Session.Adapter

  defmodule Stub do
    @behaviour PincerPorts.Session

    def process_input(sid, input), do: {:process_input, sid, input}
    def get_status(sid), do: {:status, sid}
    def reset(sid), do: {:reset, sid}
    def set_model(sid, provider, model), do: {:set_model, sid, provider, model}
    def set_thinking(sid, level), do: {:set_thinking, sid, level}
    def set_reasoning_visible(sid, v), do: {:set_reasoning_visible, sid, v}
    def set_verbose(sid, v), do: {:set_verbose, sid, v}
    def set_usage(sid, level), do: {:set_usage, sid, level}
    def approve_all(sid, seconds), do: {:approve_all, sid, seconds}
    def resolve(channel, ctx, cfg), do: {:resolve, channel, ctx, cfg}
    def start_session(sid, opts), do: {:start_session, sid, opts}
    def stop_session(sid), do: {:stop_session, sid}
    def ensure_started(sid, opts), do: {:ensure_started, sid, opts}
  end

  test "implements the Session behaviour and its callbacks" do
    behaviours =
      Adapter.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert PincerPorts.Session in behaviours

    for {fun, arity} <- PincerPorts.Session.behaviour_info(:callbacks) do
      assert function_exported?(Adapter, fun, arity),
             "Adapter does not implement #{fun}/#{arity}"
    end
  end

  test "the test double covers every port callback" do
    for {fun, arity} <- PincerPorts.Session.behaviour_info(:callbacks) do
      assert function_exported?(Stub, fun, arity),
             "Stub does not implement #{fun}/#{arity} - update it with the port"
    end
  end

  describe "port dispatch" do
    setup do
      previous = Application.get_env(:pincer, :session_adapter)
      Application.put_env(:pincer, :session_adapter, Stub)
      on_exit(fn -> restore(previous) end)
      :ok
    end

    test "routes every operation through the configured adapter" do
      assert Pincer.Ports.Session.process_input("s", "hi") == {:process_input, "s", "hi"}
      assert Pincer.Ports.Session.get_status("s") == {:status, "s"}
      assert Pincer.Ports.Session.reset("s") == {:reset, "s"}
      assert Pincer.Ports.Session.set_model("s", "p", "m") == {:set_model, "s", "p", "m"}
      assert Pincer.Ports.Session.set_thinking("s", :high) == {:set_thinking, "s", :high}
      assert Pincer.Ports.Session.set_verbose("s", true) == {:set_verbose, "s", true}
      assert Pincer.Ports.Session.set_usage("s", :full) == {:set_usage, "s", :full}
      assert Pincer.Ports.Session.start_session("s", []) == {:start_session, "s", []}
      assert Pincer.Ports.Session.stop_session("s") == {:stop_session, "s"}
      assert Pincer.Ports.Session.ensure_started("s", []) == {:ensure_started, "s", []}
    end
  end

  defp restore(nil), do: Application.delete_env(:pincer, :session_adapter)
  defp restore(value), do: Application.put_env(:pincer, :session_adapter, value)
end
