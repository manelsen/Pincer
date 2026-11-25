defmodule Pincer.Channels.CLITest do
  use ExUnit.Case, async: false

  alias Pincer.Channels.CLI

  defmodule SessionStub do
    @behaviour PincerPorts.Session

    def process_input(sid, input), do: send_fact({:process_input, sid, input})
    def get_status(sid), do: send_fact({:get_status, sid})
    def reset(sid), do: send_fact({:reset, sid})
    def set_model(sid, p, m), do: send_fact({:set_model, sid, p, m})
    def set_thinking(sid, level), do: send_fact({:set_thinking, sid, level})
    def set_reasoning_visible(sid, v), do: send_fact({:set_reasoning_visible, sid, v})
    def set_verbose(sid, v), do: send_fact({:set_verbose, sid, v})
    def set_usage(sid, level), do: send_fact({:set_usage, sid, level})
    def approve_all(sid, seconds), do: send_fact({:approve_all, sid, seconds})
    def resolve(channel, ctx, cfg), do: send_fact({:resolve, channel, ctx, cfg})
    def start_session(sid, opts), do: send_fact({:start_session, sid, opts})
    def stop_session(sid), do: send_fact({:stop_session, sid})

    def ensure_started(sid, opts) do
      send_fact({:ensure_started, sid, opts})
      {:ok, self()}
    end

    defp send_fact(msg) do
      case Application.get_env(:pincer, :test_notify_pid) do
        nil -> :ok
        pid -> send(pid, msg)
      end
    end
  end

  setup do
    previous = Application.get_env(:pincer, :session_adapter)
    Application.put_env(:pincer, :session_adapter, SessionStub)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:pincer, :session_adapter, previous),
        else: Application.delete_env(:pincer, :session_adapter)
    end)

    :ok
  end

  setup do
    Application.put_env(:pincer, :test_notify_pid, self())
    on_exit(fn -> Application.delete_env(:pincer, :test_notify_pid) end)
    :ok
  end

  # The application boots the CLI channel as a named singleton, so the tests
  # exercise that running process instead of starting a second one.
  test "attaching starts the session through the port" do
    assert GenServer.call(CLI, :attach) == :ok
    assert_receive {:ensure_started, "cli_user", []}
  end

  test "inbound user input is routed through the port" do
    GenServer.cast(CLI, {:user_input, "hello"})
    assert_receive {:process_input, "cli_user", incoming}
    assert incoming.text == "hello"
  end
end
